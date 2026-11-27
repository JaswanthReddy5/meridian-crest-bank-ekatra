# Stage 2 note – before and after

## Before calculating anything (written first, kept as it was)

Finance takes the core banking system's asset-class flag and counts loan by loan.
Risk works out days past due from the payment history and applies the borrower rule.
I believe **Risk's 4.4%** is closer to the truth. A system flag on loans that went through a rushed migration
is the weakest evidence we have, and Finance ignores the RBI borrower rule.
My guess was that the true figure is around 4.4%, perhaps a little lower.

## After the analysis

**I was only half right.** The true figure is **3.73%** (Rs 36.33 cr of Rs 974.51 cr, 533 loans). It sits between the two reports, and it is closer to Finance's figure than to Risk's.

- **Risk's method is right in principle but wrong in one detail that costs Rs 5.46 cr.**
  - It counts every bounced auto-debit (NACH) as a missed EMI, even when the borrower paid the same EMI a few days later by cash, UPI or NEFT.
  - It also spreads NPA through the vendor's 15 name-only customer matches. These are different people with different PANs and dates of birth (Rs 0.70 cr).
  - It starts the day count one day late (DPD 90 instead of 91). On 31 October that happened to move no loan into or out of NPA.
- **Finance is too low for the reasons I expected, but they are smaller than I thought.**
  - 52 migrated Pavanpur loans that were already more than 90 days late were never flagged (Rs 1.88 cr).
  - The borrower rule is missing (Rs 4.72 cr). Rs 1.39 cr of that only shows once the same person is matched across the two banks' systems.

## What the data showed that I did not expect

1. **The identity matching changes the headline number.** The vendor missed 113 Pavanpur–Meridian matches and made 15 false ones. Getting the identity right is part of the NPA figure, not only a data-cleaning step.
2. **The warehouse is not complete.**
   - 37 Pavanpur loans (Rs 5.53 cr) never reached it.
   - 12 NPA flags were lost on the way.
   - 29 balances are a day stale.
3. **Month-end lending is a real problem.**
   - 29% of all loans are sanctioned in the last 3 days of a month.
   - Compared with loans of the same product and age, they are 1.55 times as likely to be more than 30 days late (z = 7.5).
   - One Scale I officer at Belagavi Station Road (OF0038):
     - 56% of his month-end loans are more than 30 days late, against 2% of his other loans.
     - He approved 23 loans above his delegated limit, and 17 of them are now NPA.
4. **Digital-partner loans are not worse.** In raw figures they look much better than branch loans (6.5% against 12.7% late). That is only because they are younger. At the same age the difference disappears (z = −0.2).
5. **The former Pavanpur branches collect only 68–78%** of what falls due each month, against 77–92% at Meridian branches. Their slide is steady, not a one-month event: 78% of September's SMA-2 loans became NPA in October.
6. **967 Pavanpur personal loans are priced on a flat rate.** Their terms add up only under that method, so the rate on record understates what the borrower really pays.
