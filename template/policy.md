# Kleros x402 Escrow Dispute Policy

Basic policy for the Kleros x402 escrow proof of concept. Disputes under this
policy concern one question: should the payer receive the disputed amount or should the merchant?

## The facts of a case

Each dispute presents these facts, read directly from the blockchain:

- **The payer** and **the merchant**: the two addresses of the payment.
- **The token** and **the authorized amount**: what was locked in escrow.
- **The disputed amount**: what the payer claims back. It is the only amount
  the ruling decides.
- **The locked refund**: what the merchant conceded to the payer before the
  dispute, if anything. It is paid to the payer whatever the ruling.
- **The agreement**: a link to the file the payer pinned when opening the
  dispute, if any.
- **The agreement hash**: the payment's `salt`, fixed when the payer signed
  the payment. Payments made through the Kleros x402 SDK carry the hash of
  the agreement file there.

Parties may submit additional arguments and material as evidence through the court.

## The agreement file

A payer who pays through the Kleros x402 SDK has the merchant's offer saved at
payment time: the `402` response stating the resource, its description and its
price, kept in one file together with a random nonce. The SDK puts the
keccak256 of that file in the payment's `salt`, so the offer is bound to the
payment the payer signed. When the payer opens a dispute, the SDK pins the file
and links it on the case page as the agreement.

To verify the agreement, hash the linked file, for example with
`cast keccak < agreement.json`, and compare the result with the agreement hash
on the case page. If they match, the file is the offer the payer paid against,
and neither party can claim other terms. If they do not match, or no file is
linked, the offer has to be established from the evidence.

If the merchant uses x402's offer-and-receipt extension, the offer in the file
carries the merchant's signature and the paid response carries a signed
receipt. The signature proves the merchant made that offer. The receipt proves
the merchant claims to have delivered what it describes, not that the delivery
satisfies the offer.

## What the payer submits

The delivery, as evidence: the paid request and the response received, its
body or a precise account of it when it was not a file. Without the delivery,
jurors cannot know what was received.

When no agreement file is linked, or the linked file does not match the
agreement hash, the payer also submits the `402` response as evidence of the
offer.

## How to vote

1. Establish the agreement: the linked agreement file, if it hashes
   (keccak256) to the agreement hash, is the offer the payer paid against, and
   neither party can claim other terms. If no file was linked or the hash does
   not match, establish the offer from the evidence; if it cannot be
   established, vote **Pay the merchant**: a claim that cannot be checked
   against the offer cannot be upheld.
2. Establish the delivery and compare it with the offer. If the resource was
   delivered as described, vote **Pay the merchant**. If it was not delivered,
   or what was delivered materially differs from the offer, or is unusable for
   the offer's stated purpose, vote **Refund the payer**.
3. The payer bears the burden of proof: if the evidence does not establish
   that the delivery fails the offer, vote **Pay the merchant**.
4. Rulings are binary over the disputed amount. Where the payer disputed only
   part of the payment, decide whether the shortfall justifies returning that
   part.
5. Reserve **Refuse to Arbitrate** for malformed disputes. In this deployment
   a refusal is settled like **Pay the merchant**, so a merchant's failure to
   deliver is a **Refund the payer**, never a Refuse to Arbitrate.
