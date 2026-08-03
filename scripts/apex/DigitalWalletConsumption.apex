/**
 * Digital Wallet - per-card consumption summary (ecosystem-safe).
 *
 * Reproduces the numbers shown on the Digital Wallet cards UI:
 *   Total Credits, Credits Consumed, Remaining, % Consumed, % Remaining.
 *
 * Built for variability across orgs / contracts:
 *   - No hardcoded card names or dates.
 *   - Each card's ACTIVE term window [StartDate, EndDate) is fetched dynamically and bound into the
 *     consumption SOQL as :termStart / :termEnd. Cards on different contracts/terms are each scoped
 *     to their own window (MIN(startdate__c) / MAX(enddate__c) of that card's active entitlements).
 *   - utilizationdate__c varies per card; consumption is only counted if it falls inside that card's
 *     own term window, so prior-term usage never counts against the current entitlement.
 *   - Aggregation type is detected per card from usageaggregationtype__c on the consumption DMO:
 *       SUM -> cumulative drawdown: SUM(unitsconsumed__c) within the term.
 *       MAX -> point-in-time allocation (e.g. storage): latest Production snapshot
 *              (most recent utilizationdate__c) within the term.
 *
 * Metrics:
 *   Total Credits = SUM(quantity__c) from TenantEntitlementTransaction__dlm
 *     (Add/Reduction, excl. Reparenting, active StartDate <= TODAY < EndDate), net of reductions.
 *   Remaining = Total - Consumed; %Consumed = 100*Consumed/Total; %Remaining = 100*Remaining/Total.
 *
 * Run:
 *   sf apex run --file scripts/apex/DigitalWalletConsumption.apex --target-org <alias>
 */

// Step 1: Active entitlements per card -> Total Credits + that card's own term window.
Map<String, Decimal>  totalByCard     = new Map<String, Decimal>();
Map<String, Datetime> termStartByCard = new Map<String, Datetime>();
Map<String, Datetime> termEndByCard   = new Map<String, Datetime>();
for (AggregateResult ar : [
    SELECT entitlementcarddefdevlname__c card, SUM(quantity__c) total,
           MIN(startdate__c) termStart, MAX(enddate__c) termEnd
    FROM TenantEntitlementTransaction__dlm
    WHERE entitlementtransactiontype__c IN ('Add','Reduction')
      AND (entitlementtransactionsubtype__c != 'Reparenting'
           OR entitlementtransactionsubtype__c = null)
      AND startdate__c <= TODAY
      AND enddate__c > TODAY
    GROUP BY entitlementcarddefdevlname__c
]) {
    String card = (String)ar.get('card');
    // NOTE: SUM() on a Data Cloud DMO returns a Double (not a Decimal like standard sObjects).
    // Doubles render large values in scientific notation (e.g. 1.0E+12) and don't normalize when
    // boxed into a Decimal map. Coerce to a true Decimal via String so values print in full.
    Object totalObj = ar.get('total');
    Decimal totalVal = (totalObj == null) ? 0 : Decimal.valueOf(String.valueOf(totalObj));
    totalByCard.put(card, totalVal);
    termStartByCard.put(card, (Datetime)ar.get('termStart'));
    termEndByCard.put(card, (Datetime)ar.get('termEnd'));
}

// Step 2: Detect each card's consumption aggregation type (SUM vs MAX). Prefer MAX if mixed.
Map<String, String> aggTypeByCard = new Map<String, String>();
for (AggregateResult ar : [
    SELECT carddefinitiondevelopername__c card, usageaggregationtype__c aggType
    FROM TenantDailyEntitlementConsumption__dlm
    GROUP BY carddefinitiondevelopername__c, usageaggregationtype__c
]) {
    String card = (String)ar.get('card');
    String aggType = (String)ar.get('aggType');
    if (!aggTypeByCard.containsKey(card) || aggType == 'MAX') {
        aggTypeByCard.put(card, aggType);
    }
}

// Step 3: Consumed per card, scoped to that card's own term window (bind variables), honoring aggType.
Map<String, Decimal> consumedByCard = new Map<String, Decimal>();
for (String card : totalByCard.keySet()) {
    Datetime termStart = termStartByCard.get(card);
    Datetime termEnd   = termEndByCard.get(card);
    String aggType     = aggTypeByCard.get(card);
    Decimal consumed   = 0;

    if (aggType == 'MAX') {
        // Point-in-time allocation: latest Production snapshot within the term.
        List<TenantDailyEntitlementConsumption__dlm> snap = [
            SELECT unitsconsumed__c
            FROM TenantDailyEntitlementConsumption__dlm
            WHERE carddefinitiondevelopername__c = :card
              AND Usage_Business_Environment_Type__c = 'Production'
              AND utilizationdate__c >= :termStart
              AND utilizationdate__c <  :termEnd
            ORDER BY utilizationdate__c DESC
            LIMIT 1
        ];
        if (snap.isEmpty()) {
            // Fallback: latest reading in any environment within the term.
            snap = [
                SELECT unitsconsumed__c
                FROM TenantDailyEntitlementConsumption__dlm
                WHERE carddefinitiondevelopername__c = :card
                  AND utilizationdate__c >= :termStart
                  AND utilizationdate__c <  :termEnd
                ORDER BY utilizationdate__c DESC
                LIMIT 1
            ];
        }
        consumed = (snap.isEmpty() || snap[0].unitsconsumed__c == null)
            ? 0 : Decimal.valueOf(String.valueOf(snap[0].unitsconsumed__c));
    } else {
        // Cumulative drawdown: sum within the term.
        AggregateResult[] rs = [
            SELECT SUM(unitsconsumed__c) consumed
            FROM TenantDailyEntitlementConsumption__dlm
            WHERE carddefinitiondevelopername__c = :card
              AND utilizationdate__c >= :termStart
              AND utilizationdate__c <  :termEnd
        ];
        Object consumedObj = rs.isEmpty() ? null : rs[0].get('consumed');
        consumed = (consumedObj == null) ? 0 : Decimal.valueOf(String.valueOf(consumedObj));
    }
    consumedByCard.put(card, consumed);
}

// Step 4: Report the real wallet cards (those with an active entitlement).
System.debug('=== Digital Wallet Consumption ===');
System.debug('Card | AggType | TermStart | TermEnd | TotalCredits | Consumed | Remaining | %Consumed | %Remaining | Note');
List<String> cardNames = new List<String>(totalByCard.keySet());
cardNames.sort();
// Entitlements at/above this threshold are provisioned as effectively "unlimited".
Decimal UNLIMITED_THRESHOLD = 1000000000000L;
for (String card : cardNames) {
    Decimal total = totalByCard.get(card);
    Decimal consumed = consumedByCard.get(card) == null ? 0 : consumedByCard.get(card);
    Decimal remaining = total - consumed;
    Decimal pctConsumed  = (total != 0) ? (consumed / total * 100).setScale(2) : null;
    Decimal pctRemaining = (total != 0) ? (remaining / total * 100).setScale(2) : null;
    String aggType = aggTypeByCard.containsKey(card) ? aggTypeByCard.get(card) : 'SUM';
    String note = (total >= UNLIMITED_THRESHOLD) ? 'UNLIMITED' : '';
    System.debug(card + ' | ' + aggType + ' | ' + termStartByCard.get(card) + ' | ' + termEndByCard.get(card)
        + ' | ' + total.toPlainString() + ' | ' + consumed.toPlainString() + ' | ' + remaining.toPlainString()
        + ' | ' + pctConsumed + ' | ' + pctRemaining + ' | ' + note);
}
