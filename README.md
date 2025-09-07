# ERC 1155 Based Multi-Owner (Individual Property) Will Demonstration

This demonstration showcases a **test version of Multi-Owner Multi-Heir Will** on Remix IDE.  
We present the process step by step with screenshots.

---

## Contract Deployment
The owner with the address `0x5B3xxxdC4` deploys the contract.  
He then creates an asset with three owners:

- `0x5B3xxxxdC4` → 100 coins  
- `0xAb8xxxxcb2` → 200 coins  
- `0x4B2xxx2db` → 300 coins  

<p align="center">
  <img src="individual prop/fig1.png" class="demo-img" alt="Contract Deployment"/>
</p>

---

## Multi-Owner Multi-Heir: Individual Will Creation
The asset has been created with **AssetID: 1**, with the holders (owners) as shown below.

<p align="center">
  <img src="individual prop/fig2.png" class="demo-img" alt="Asset Creation"/>
</p>

---

## Setting the WillManager
The creator of **AssetID: 1** sets the `WillManager` with the NFT address `0xC7BxxxB94` and deploys.  
Thus, the `WillManager` gets an address `0xfB7xxx7e4`.  


<p align="center">
  <img src="individual prop/fig2.png" class="demo-img" alt="WillManager Setup"/>
</p>


Thereafter, **all the owners approve the WillManager** for managing their cryptowill.

<p align="center">
  <img src="individual prop/fig2b.png" class="demo-img" alt="WillManager Setup"/>
</p>

---

## Creating the Multi-Owner Multi-Heir Will
Now the `WillManager` creates a Multi-Owner Multi-Heir Will with **individual shares**:

- **TokenID:** 1  
- **Heir Address:** `0xdD8xxx148`  
- **Date of Birth:** (UNIX timestamp)  
- **Condition:** 18 years  
- **Vesting Period:** 0  
- **Token Amount:** 50  
- **Trustees:** `0x787xxxbaB`, `0x617xxx7f2`  
- **Required Trustee Signatures:** 2  

<p align="center">
  <img src="individual prop/fig3.png" class="demo-img" alt="Will Creation"/>
</p>

---

## Trustee-Based Execution
If the owner fails to respond within the **response time = 60 sec**,  
the transfer depends on the Trustees' signatures.  
Below, the owner does not respond within the due time.

<p align="center">
  <img src="individual prop/fig4.png" class="demo-img" alt="Trustee Execution"/>
</p>
<p align="center">
  <img src="individual prop/fig5.png" class="demo-img" alt="Trustee Execution"/>
</p>


---

## Seamless Transfer to Heir
After the Trustees sign, the death is approved, and the transfer is seamless.  
The heir’s account gets credited successfully.

<p align="center">
  <img src="individual prop/fig5.png" class="demo-img" alt="Heir Credit"/>
</p>

---

## Summary
This demonstration shows how the **Multi-Owner Multi-Heir Will** works on the testnet with:

- ✅ Multiple owners  
- ✅ Individual will creation  
- ✅ Trustee-based execution  
- ✅ Seamless transfer to heirs  


