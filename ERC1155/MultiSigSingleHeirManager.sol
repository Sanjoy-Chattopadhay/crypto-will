// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MultiOwnerSingleHeirWillManager
 * @notice Manages (a) single-heir wills for portions of ERC-1155 assets and
 *         (b) whole-property proposals requiring approvals from *current* holders.
 *         Enhanced with debugging functions for clear Remix testing.
 */

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

interface IMultiOwnerNFT {
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function isApprovedForAll(address account, address operator) external view returns (bool);
    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external;
    function getHolders(uint256 id) external view returns (address[] memory);
}

contract MultiOwnerSingleHeirWillManager is ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;

    IMultiOwnerNFT public immutable nft;

    // --- Parameters ---
    uint64 public deathDetectionPeriod = 1 minutes; // set to 365 days for prod

    // --- Errors ---
    error NotWillOwner();
    error WillNotActive();
    error WillAlreadyExecuted();
    error InvalidHeir();
    error InvalidTrustees();
    error TooManyRequiredSignatures();
    error NotTrustee();
    error AlreadyApproved();
    error NotDeadYet();
    error NeedMoreTrusteeApprovals();
    error NotHeir();
    error TooEarly();
    error MissingApprovalForAll(address owner, address operator);
    error NoHolders();
    error NotAHolder();
    error AlreadyApprovedProposal();
    error ProposalNotReady();
    error InvalidRecipient();

    // --- Events ---
    event WillCreated(address indexed owner, uint256 indexed willId, uint256 tokenId, uint256 amount, address heir);
    event Heartbeat(address indexed owner, uint64 timestamp);
    event DeathApproved(address indexed owner, uint256 indexed willId, address trustee, uint256 approvals, uint256 required);
    event InheritanceExecuted(address indexed owner, uint256 indexed willId, address heir, bool immediate);
    event EscrowClaimed(uint256 indexed willId, address heir);

    event ProposalCreated(uint256 indexed tokenId, address recipient);
    event ProposalApproved(uint256 indexed tokenId, address owner, uint256 approvals, uint256 totalOwners);
    event ProposalExecuted(uint256 indexed tokenId, address recipient);

    constructor(IMultiOwnerNFT nft_) {
        nft = nft_;
    }

    // --- Individual Wills ---

    struct IndividualWill {
        address owner;
        address heir;
        uint64 heirBirthDate; // epoch seconds
        uint8 minimumHeirAge; // years
        uint64 vestingPeriod; // seconds after death approval threshold met
        uint256 tokenId;
        uint256 tokenAmount;

        // liveness
        uint64 lastHeartbeat;
        bool active;
        bool executed;

        // trustees
        address[] trustees;
        uint8 requiredSignatures;
        mapping(address => bool) trusteeApproved;

        // escrow
        bool inEscrow;
        uint64 unlockTimestamp;
    }

    // owner => list of wills
    mapping(address => IndividualWill[]) private _wills;

    function createIndividualWill(
        uint256 tokenId,
        address heir,
        uint64 heirBirthDate,
        uint8 minimumHeirAge,
        uint64 vestingPeriod,
        uint256 tokenAmount,
        address[] calldata trustees,
        uint8 requiredSignatures
    ) external returns (uint256 willId) {
        if (heir == address(0) || heir == msg.sender) revert InvalidHeir();
        if (trustees.length == 0) revert InvalidTrustees();
        if (requiredSignatures == 0 || requiredSignatures > trustees.length) revert TooManyRequiredSignatures();
        if (nft.balanceOf(msg.sender, tokenId) < tokenAmount) revert NotWillOwner();

        _wills[msg.sender].push();
        willId = _wills[msg.sender].length - 1;
        IndividualWill storage w = _wills[msg.sender][willId];

        w.owner = msg.sender;
        w.heir = heir;
        w.heirBirthDate = heirBirthDate;
        w.minimumHeirAge = minimumHeirAge;
        w.vestingPeriod = vestingPeriod;
        w.tokenId = tokenId;
        w.tokenAmount = tokenAmount;
        w.lastHeartbeat = uint64(block.timestamp);
        w.active = true;
        w.executed = false;

        // copy trustees
        w.trustees = trustees;
        w.requiredSignatures = requiredSignatures;

        emit WillCreated(msg.sender, willId, tokenId, tokenAmount, heir);
        emit Heartbeat(msg.sender, w.lastHeartbeat);
    }

    function recordHeartbeat() external {
        // latest will timestamp wins conceptually; we don't identify willId here.
        // You can also set per-will if you prefer; for simplicity we update all active ones.
        IndividualWill[] storage arr = _wills[msg.sender];
        uint64 ts = uint64(block.timestamp);
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i].active && !arr[i].executed) {
                arr[i].lastHeartbeat = ts;
            }
        }
        emit Heartbeat(msg.sender, ts);
    }

    function approveDeath(address willOwner, uint256 willId) external {
        IndividualWill storage w = _wills[willOwner][willId];
        if (!w.active) revert WillNotActive();

        // must be a trustee
        bool isTrustee;
        for (uint256 i = 0; i < w.trustees.length; i++) {
            if (w.trustees[i] == msg.sender) {
                isTrustee = true;
                break;
            }
        }
        if (!isTrustee) revert NotTrustee();

        if (block.timestamp < (uint256(w.lastHeartbeat) + uint256(deathDetectionPeriod))) revert NotDeadYet();
        if (w.trusteeApproved[msg.sender]) revert AlreadyApproved();

        w.trusteeApproved[msg.sender] = true;

        // count approvals
        uint256 approvals;
        for (uint256 i = 0; i < w.trustees.length; i++) {
            if (w.trusteeApproved[w.trustees[i]]) approvals++;
        }

        emit DeathApproved(willOwner, willId, msg.sender, approvals, w.requiredSignatures);
    }

    /// @notice Execute inheritance after enough trustee approvals.
    ///         Anyone can call after threshold; actual transfer may go to escrow.
    function executeInheritance(address willOwner, uint256 willId) external nonReentrant {
        IndividualWill storage w = _wills[willOwner][willId];
        if (!w.active) revert WillNotActive();
        if (w.executed) revert WillAlreadyExecuted();

        if (block.timestamp < (uint256(w.lastHeartbeat) + uint256(deathDetectionPeriod))) revert NotDeadYet();

        // count approvals
        uint256 approvals;
        for (uint256 i = 0; i < w.trustees.length; i++) {
            if (w.trusteeApproved[w.trustees[i]]) approvals++;
        }
        if (approvals < w.requiredSignatures) revert NeedMoreTrusteeApprovals();

        // Must be approved for transfer
        if (!nft.isApprovedForAll(w.owner, address(this))) {
            revert MissingApprovalForAll(w.owner, address(this));
        }

        // Check age
        bool meetsAge = _ageYears(w.heirBirthDate, uint64(block.timestamp)) >= w.minimumHeirAge;

        // If vesting applies, unlock occurs now + vesting
        uint64 unlock = uint64(block.timestamp) + w.vestingPeriod;

        if (meetsAge && w.vestingPeriod == 0) {
            // Immediate transfer
            nft.safeTransferFrom(w.owner, w.heir, w.tokenId, w.tokenAmount, "");
            w.executed = true;
            w.active = false;
            emit InheritanceExecuted(w.owner, willId, w.heir, true);
        } else {
            // Move to escrow: contract holds the tokens first
            nft.safeTransferFrom(w.owner, address(this), w.tokenId, w.tokenAmount, "");
            w.inEscrow = true;
            w.unlockTimestamp = unlock;
            w.executed = true; // will executed; now pending claim
            w.active = false;
            emit InheritanceExecuted(w.owner, willId, w.heir, false);
        }
    }

    function claimLockedInheritance(address willOwner, uint256 willId) external nonReentrant {
        IndividualWill storage w = _wills[willOwner][willId];
        if (!w.executed || !w.inEscrow) revert WillAlreadyExecuted();
        if (msg.sender != w.heir) revert NotHeir();
        if (block.timestamp < w.unlockTimestamp) revert TooEarly();

        // Transfer from escrow (this contract) to heir
        // No approval needed when sending from this contract
        nft.safeTransferFrom(address(this), w.heir, w.tokenId, w.tokenAmount, "");
        w.inEscrow = false;
        emit EscrowClaimed(willId, w.heir);
    }

    // --- Enhanced Individual Will Debugging Functions ---

    struct WillDebugInfo {
        address owner;
        address heir;
        uint64 heirBirthDate;
        uint8 minimumHeirAge;
        uint64 vestingPeriod;
        uint256 tokenId;
        uint256 tokenAmount;
        uint64 lastHeartbeat;
        bool active;
        bool executed;
        address[] trustees;
        uint8 requiredSignatures;
        bool inEscrow;
        uint64 unlockTimestamp;
        uint256 currentApprovals;
        uint64 currentTimestamp;
        bool isDeadByTime;
        uint8 currentHeirAge;
    }

    function getWillDebugInfo(address owner, uint256 willId) external view returns (WillDebugInfo memory info) {
        require(willId < _wills[owner].length, "Will does not exist");
        IndividualWill storage w = _wills[owner][willId];
        
        // Count current approvals
        uint256 approvals;
        for (uint256 i = 0; i < w.trustees.length; i++) {
            if (w.trusteeApproved[w.trustees[i]]) approvals++;
        }

        info = WillDebugInfo({
            owner: w.owner,
            heir: w.heir,
            heirBirthDate: w.heirBirthDate,
            minimumHeirAge: w.minimumHeirAge,
            vestingPeriod: w.vestingPeriod,
            tokenId: w.tokenId,
            tokenAmount: w.tokenAmount,
            lastHeartbeat: w.lastHeartbeat,
            active: w.active,
            executed: w.executed,
            trustees: w.trustees,
            requiredSignatures: w.requiredSignatures,
            inEscrow: w.inEscrow,
            unlockTimestamp: w.unlockTimestamp,
            currentApprovals: approvals,
            currentTimestamp: uint64(block.timestamp),
            isDeadByTime: block.timestamp >= (uint256(w.lastHeartbeat) + uint256(deathDetectionPeriod)),
            currentHeirAge: _ageYears(w.heirBirthDate, uint64(block.timestamp))
        });
    }

    function checkTrusteeApproval(address owner, uint256 willId, address trustee) external view returns (bool) {
        require(willId < _wills[owner].length, "Will does not exist");
        return _wills[owner][willId].trusteeApproved[trustee];
    }

    function getWillCount(address owner) external view returns (uint256) {
        return _wills[owner].length;
    }

    // --- Whole Property Proposals ---

    struct WholePropertyProposal {
        address recipient;
        bool executed;
        // approvals tracking
        mapping(address => bool) approved;
        uint256 approvalsCount;
    }

    // tokenId => proposal (single live proposal at a time for simplicity)
    mapping(uint256 => WholePropertyProposal) private _proposal;

    function createWholePropertyProposal(uint256 tokenId, address recipient) external {
        if (recipient == address(0)) revert InvalidRecipient();

        // must be a *current* holder
        if (nft.balanceOf(msg.sender, tokenId) == 0) revert NotAHolder();

        WholePropertyProposal storage p = _proposal[tokenId];
        require(p.recipient == address(0) || p.executed, "Active proposal exists");
        
        // Reset proposal state
        p.recipient = recipient;
        p.executed = false;
        p.approvalsCount = 0;

        emit ProposalCreated(tokenId, recipient);
    }

    function approveWholeProperty(uint256 tokenId) external {
        // must be a *current* holder
        if (nft.balanceOf(msg.sender, tokenId) == 0) revert NotAHolder();

        WholePropertyProposal storage p = _proposal[tokenId];
        require(p.recipient != address(0) && !p.executed, "No active proposal");
        if (p.approved[msg.sender]) revert AlreadyApprovedProposal();

        p.approved[msg.sender] = true;
        p.approvalsCount += 1;

        // total owners at the time of approval check
        address[] memory holders = nft.getHolders(tokenId);
        if (holders.length == 0) revert NoHolders();

        emit ProposalApproved(tokenId, msg.sender, p.approvalsCount, holders.length);

        // If everyone approved, execute
        bool allApproved = true;
        for (uint256 i = 0; i < holders.length; i++) {
            if (nft.balanceOf(holders[i], tokenId) > 0 && !p.approved[holders[i]]) {
                allApproved = false;
                break;
            }
        }
        if (allApproved) {
            _executeWholeProperty(tokenId, p.recipient, holders);
        }
    }

    function executeWholeProperty(uint256 tokenId) external nonReentrant {
        WholePropertyProposal storage p = _proposal[tokenId];
        require(p.recipient != address(0) && !p.executed, "No active proposal");
        address[] memory holders = nft.getHolders(tokenId);
        if (holders.length == 0) revert NoHolders();

        // Ensure unanimous approval from current holders with positive balance
        for (uint256 i = 0; i < holders.length; i++) {
            if (nft.balanceOf(holders[i], tokenId) > 0 && !p.approved[holders[i]]) {
                revert ProposalNotReady();
            }
        }
        _executeWholeProperty(tokenId, p.recipient, holders);
    }

    function _executeWholeProperty(uint256 tokenId, address recipient, address[] memory holders) internal {
        // Each holder must have approved; then transfer all balances to recipient
        for (uint256 i = 0; i < holders.length; i++) {
            uint256 bal = nft.balanceOf(holders[i], tokenId);
            if (bal > 0) {
                if (!nft.isApprovedForAll(holders[i], address(this))) {
                    revert MissingApprovalForAll(holders[i], address(this));
                }
                nft.safeTransferFrom(holders[i], recipient, tokenId, bal, "");
            }
        }
        _proposal[tokenId].executed = true;
        emit ProposalExecuted(tokenId, recipient);
    }

    // --- Enhanced Whole Property Debugging Functions ---

    struct ProposalDebugInfo {
        address recipient;
        bool executed;
        uint256 approvalsCount;
        address[] currentHolders;
        uint256[] currentBalances;
        bool[] approvalStatus;
        bool[] hasApprovedManager;
        bool allApproved;
        uint256 totalHoldersWithBalance;
    }

    function getProposalDebugInfo(uint256 tokenId) external view returns (ProposalDebugInfo memory info) {
        WholePropertyProposal storage p = _proposal[tokenId];
        address[] memory holders = nft.getHolders(tokenId);
        
        uint256[] memory balances = new uint256[](holders.length);
        bool[] memory approvals = new bool[](holders.length);
        bool[] memory managerApprovals = new bool[](holders.length);
        
        bool allApproved = true;
        uint256 holdersWithBalance = 0;
        
        for (uint256 i = 0; i < holders.length; i++) {
            balances[i] = nft.balanceOf(holders[i], tokenId);
            approvals[i] = p.approved[holders[i]];
            managerApprovals[i] = nft.isApprovedForAll(holders[i], address(this));
            
            if (balances[i] > 0) {
                holdersWithBalance++;
                if (!approvals[i]) {
                    allApproved = false;
                }
            }
        }

        info = ProposalDebugInfo({
            recipient: p.recipient,
            executed: p.executed,
            approvalsCount: p.approvalsCount,
            currentHolders: holders,
            currentBalances: balances,
            approvalStatus: approvals,
            hasApprovedManager: managerApprovals,
            allApproved: allApproved,
            totalHoldersWithBalance: holdersWithBalance
        });
    }

    function checkProposalApproval(uint256 tokenId, address holder) external view returns (bool) {
        return _proposal[tokenId].approved[holder];
    }

    function getProposalRecipient(uint256 tokenId) external view returns (address) {
        return _proposal[tokenId].recipient;
    }

    function isProposalExecuted(uint256 tokenId) external view returns (bool) {
        return _proposal[tokenId].executed;
    }

    function getProposalApprovalsCount(uint256 tokenId) external view returns (uint256) {
        return _proposal[tokenId].approvalsCount;
    }

    // --- Quick Status Functions ---

    function getTokenHoldersWithBalances(uint256 tokenId) external view returns (address[] memory holders, uint256[] memory balances) {
        holders = nft.getHolders(tokenId);
        balances = new uint256[](holders.length);
        for (uint256 i = 0; i < holders.length; i++) {
            balances[i] = nft.balanceOf(holders[i], tokenId);
        }
    }

    function checkAllApprovalsForToken(uint256 tokenId) external view returns (address[] memory holders, bool[] memory approvedManager, bool[] memory approvedProposal) {
        holders = nft.getHolders(tokenId);
        approvedManager = new bool[](holders.length);
        approvedProposal = new bool[](holders.length);
        
        for (uint256 i = 0; i < holders.length; i++) {
            approvedManager[i] = nft.isApprovedForAll(holders[i], address(this));
            approvedProposal[i] = _proposal[tokenId].approved[holders[i]];
        }
    }

    // --- Utils ---

    function setDeathDetectionPeriod(uint64 newPeriod) external {
        // simple admin: anyone can increase for testing; in prod, guard with Ownable if desired
        deathDetectionPeriod = newPeriod;
    }

    function _ageYears(uint64 birthDate, uint64 now_) internal pure returns (uint8) {
        if (now_ <= birthDate) return 0;
        uint256 years_ = (uint256(now_) - uint256(birthDate)) / 365 days;
        if (years_ > type(uint8).max) years_ = type(uint8).max;
        return uint8(years_);
    }

    // --- ERC1155 Receiver (required for escrow functionality) ---
    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes memory
    ) public pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    ) public pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }
}