/**
 * Tests for DigitalWalletConsumptionService.
 *
 * The Data 360 DMOs can't be created via DML. Typed query responses are mocked
 * with the native SoqlStubProvider pattern (Test.createSoqlStub +
 * Test.createStubQueryRow). The one aggregate (SUM) call can't be mocked, so its
 * value is injected through the service's @TestVisible seams (aggTypeOverride /
 * consumedOverride / sumConsumedOverride).
 */
@IsTest
public class DigitalWalletConsumptionServiceTest {

    static final Datetime T_START = Datetime.newInstanceGmt(2025, 11, 13, 23, 0, 0);
    static final Datetime T_END   = Datetime.newInstanceGmt(2026, 11, 13, 23, 0, 0);
    static final Datetime IN_WIN  = Datetime.newInstanceGmt(2026, 1, 1, 0, 0, 0);

    // Rows returned by the stubs for the current test.
    static List<SObject> entRows  = new List<SObject>();
    static List<SObject> consRows = new List<SObject>();
    static List<SObject> prodRows = new List<SObject>();   // for the snapshot Production query
    static List<SObject> anyRows  = new List<SObject>();   // for the snapshot fallback query

    // ---- SOQL stubs ----
    public class EntitlementStub extends SoqlStubProvider {
        public override List<SObject> handleSoqlQuery(Schema.SObjectType sot, String q, Map<String, Object> b) {
            Assert.areEqual(TenantEntitlementTransaction__dlm.sObjectType, sot);
            return entRows;
        }
    }
    public class ConsumptionStub extends SoqlStubProvider {
        public override List<SObject> handleSoqlQuery(Schema.SObjectType sot, String q, Map<String, Object> b) {
            Assert.areEqual(TenantDailyEntitlementConsumption__dlm.sObjectType, sot);
            return consRows;
        }
    }
    // Returns Production vs any-environment rows based on the query text so the
    // maxSnapshotForCard Production-then-fallback logic can be exercised.
    public class SnapshotStub extends SoqlStubProvider {
        public override List<SObject> handleSoqlQuery(Schema.SObjectType sot, String q, Map<String, Object> b) {
            return q.contains('Production') ? prodRows : anyRows;
        }
    }

    // ---- Row builders ----
    static SObject ent(String card, Decimal qty, Datetime startDt, Datetime endDt) {
        return Test.createStubQueryRow(TenantEntitlementTransaction__dlm.sObjectType, new Map<String, Object>{
            'entitlementcarddefdevlname__c' => card,
            'quantity__c'                   => qty,
            'startdate__c'                  => startDt,
            'enddate__c'                    => endDt,
            'entitlementtransactiontype__c' => (qty >= 0 ? 'Add' : 'Reduction')
        });
    }
    static SObject con(String card, String aggType, Decimal units, Datetime utilDt, String env) {
        return Test.createStubQueryRow(TenantDailyEntitlementConsumption__dlm.sObjectType, new Map<String, Object>{
            'carddefinitiondevelopername__c'     => card,
            'usageaggregationtype__c'            => aggType,
            'unitsconsumed__c'                   => units,
            'utilizationdate__c'                 => utilDt,
            'Usage_Business_Environment_Type__c' => env
        });
    }

    static Map<String, DigitalWalletConsumptionService.CardConsumption> indexByCard(
            List<DigitalWalletConsumptionService.CardConsumption> rows) {
        Map<String, DigitalWalletConsumptionService.CardConsumption> m =
            new Map<String, DigitalWalletConsumptionService.CardConsumption>();
        for (DigitalWalletConsumptionService.CardConsumption c : rows) {
            m.put(c.card, c);
        }
        return m;
    }

    static void registerEnt() {
        Test.createSoqlStub(TenantEntitlementTransaction__dlm.sObjectType, new EntitlementStub());
    }
    static void registerCons() {
        Test.createSoqlStub(TenantDailyEntitlementConsumption__dlm.sObjectType, new ConsumptionStub());
    }
    static void registerSnap() {
        Test.createSoqlStub(TenantDailyEntitlementConsumption__dlm.sObjectType, new SnapshotStub());
    }

    // Injects per-card aggregation type + consumed so computeConsumption() runs
    // deterministically without the (unmockable) aggregate consumption queries.
    static void injectConsumption(Map<String, String> aggTypes, Map<String, Decimal> consumed) {
        DigitalWalletConsumptionService.aggTypeOverride  = aggTypes;
        DigitalWalletConsumptionService.consumedOverride = consumed;
    }

    // =========================================================================
    // computeConsumption end-to-end (entitlements stubbed; consumption injected)
    // =========================================================================

    @IsTest
    static void computesAllCardScenarios() {
        entRows = new List<SObject>{
            // FlexCredits: Add 500000 + Reduction -100000 => net 400000 (SUM card)
            ent('FlexCredits', 500000, T_START, T_END),
            ent('FlexCredits', -100000, T_START, T_END),
            // DataStorageCard: 6144 (MAX / snapshot card)
            ent('DataStorageCard', 6144, T_START, T_END),
            // Personalization: effectively unlimited
            ent('Personalization', 1000000000000L, T_START, T_END),
            // Null card developer name => skipped by computeConsumption.
            ent(null, 100, T_START, T_END)
        };
        injectConsumption(
            new Map<String, String>{ 'FlexCredits' => 'SUM', 'DataStorageCard' => 'MAX', 'Personalization' => 'SUM' },
            new Map<String, Decimal>{ 'FlexCredits' => 361702, 'DataStorageCard' => 248.17, 'Personalization' => 0 });
        registerEnt();

        Test.startTest();
        List<DigitalWalletConsumptionService.CardConsumption> res =
            DigitalWalletConsumptionService.computeConsumption();
        Test.stopTest();

        Assert.areEqual(3, res.size(), 'Expected one row per active card');
        Map<String, DigitalWalletConsumptionService.CardConsumption> m = indexByCard(res);

        DigitalWalletConsumptionService.CardConsumption flex = m.get('FlexCredits');
        Assert.areEqual('SUM', flex.aggType);
        Assert.areEqual(400000, flex.totalCredits.intValue());
        Assert.areEqual(361702, flex.consumed.intValue());
        Assert.areEqual(38298, flex.remaining.intValue());
        Assert.areEqual(90.43, flex.pctConsumed);
        Assert.areEqual(9.57, flex.pctRemaining);
        Assert.areEqual('', flex.note);

        DigitalWalletConsumptionService.CardConsumption ds = m.get('DataStorageCard');
        Assert.areEqual('MAX', ds.aggType);
        Assert.areEqual(6144, ds.totalCredits.intValue());
        Assert.areEqual(248.17, ds.consumed);
        Assert.areEqual(5895.83, ds.remaining);
        Assert.areEqual(4.04, ds.pctConsumed);
        Assert.areEqual(95.96, ds.pctRemaining);

        DigitalWalletConsumptionService.CardConsumption p = m.get('Personalization');
        Assert.areEqual(0, p.consumed.intValue());
        Assert.areEqual('1000000000000', p.totalCredits.toPlainString());
        Assert.areEqual('UNLIMITED', p.note);
        Assert.areEqual(0.00, p.pctConsumed);
        Assert.areEqual(100.00, p.pctRemaining);
    }

    @IsTest
    static void returnsEmptyWhenNoEntitlements() {
        entRows = new List<SObject>();
        registerEnt();

        Test.startTest();
        List<DigitalWalletConsumptionService.CardConsumption> res =
            DigitalWalletConsumptionService.computeConsumption();
        Test.stopTest();

        Assert.areEqual(0, res.size(), 'No active entitlements should yield no cards');
    }

    // =========================================================================
    // Per-card query seams (typed queries are mockable)
    // =========================================================================

    @IsTest
    static void aggTypeForCardClassifies() {
        registerCons();

        consRows = new List<SObject>{ con('C', 'MAX', 1, IN_WIN, 'Production') };
        Assert.areEqual('MAX', DigitalWalletConsumptionService.aggTypeForCard('C'),
            'A card with a MAX probe row is a MAX card');

        consRows = new List<SObject>();
        Assert.areEqual('SUM', DigitalWalletConsumptionService.aggTypeForCard('C'),
            'A card with no MAX probe row defaults to SUM');
    }

    @IsTest
    static void aggTypeForCardHonorsOverride() {
        DigitalWalletConsumptionService.aggTypeOverride = new Map<String, String>{ 'C' => 'MAX' };
        Assert.areEqual('MAX', DigitalWalletConsumptionService.aggTypeForCard('C'),
            'The override should short-circuit the query');
    }

    @IsTest
    static void maxSnapshotForCardStrategies() {
        registerSnap();

        // Latest Production snapshot within the term.
        prodRows = new List<SObject>{ con('C', 'MAX', 248.17, IN_WIN, 'Production') };
        anyRows  = new List<SObject>{ con('C', 'MAX', 9999, IN_WIN, 'Sandbox') };
        Assert.areEqual(248.17,
            DigitalWalletConsumptionService.maxSnapshotForCard('C', T_START, T_END),
            'Production snapshot should win when present');

        // No Production reading -> fallback to latest in any environment.
        prodRows = new List<SObject>();
        anyRows  = new List<SObject>{ con('C', 'MAX', 500, IN_WIN, 'Sandbox') };
        Assert.areEqual(500,
            DigitalWalletConsumptionService.maxSnapshotForCard('C', T_START, T_END).intValue(),
            'Fallback reading should be used when no Production snapshot exists');

        // No readings at all -> zero.
        prodRows = new List<SObject>();
        anyRows  = new List<SObject>();
        Assert.areEqual(0,
            DigitalWalletConsumptionService.maxSnapshotForCard('C', T_START, T_END).intValue(),
            'No readings should yield zero');
    }

    @IsTest
    static void consumedForCardDispatchesAndHonorsOverrides() {
        registerSnap();

        // SUM branch via the sum override (avoids the unmockable aggregate SOQL).
        DigitalWalletConsumptionService.sumConsumedOverride = new Map<String, Decimal>{ 'C' => 1234 };
        Assert.areEqual(1234,
            DigitalWalletConsumptionService.consumedForCard('C', 'SUM', T_START, T_END).intValue(),
            'SUM dispatch should return the summed value');
        Assert.areEqual(1234,
            DigitalWalletConsumptionService.sumConsumedForCard('C', T_START, T_END).intValue(),
            'sumConsumedForCard should honor its override');

        // MAX branch dispatches to the snapshot query.
        prodRows = new List<SObject>{ con('C', 'MAX', 77, IN_WIN, 'Production') };
        Assert.areEqual(77,
            DigitalWalletConsumptionService.consumedForCard('C', 'MAX', T_START, T_END).intValue(),
            'MAX dispatch should return the snapshot value');

        // consumedForCard override short-circuits both strategies.
        DigitalWalletConsumptionService.consumedOverride = new Map<String, Decimal>{ 'C' => 55 };
        Assert.areEqual(55,
            DigitalWalletConsumptionService.consumedForCard('C', 'SUM', T_START, T_END).intValue(),
            'The consumed override should short-circuit the query');
    }

    // =========================================================================
    // Email / summary rendering
    // =========================================================================

    @IsTest
    static void logSummaryRunsWithoutError() {
        entRows = new List<SObject>{ ent('FlexCredits', 400000, T_START, T_END) };
        injectConsumption(
            new Map<String, String>{ 'FlexCredits' => 'SUM' },
            new Map<String, Decimal>{ 'FlexCredits' => 1000 });
        registerEnt();

        Test.startTest();
        DigitalWalletConsumptionService.logSummary();
        Test.stopTest();
    }

    @IsTest
    static void buildSummaryEmailComposesMessage() {
        entRows = new List<SObject>{ ent('FlexCredits', 400000, T_START, T_END) };
        injectConsumption(
            new Map<String, String>{ 'FlexCredits' => 'SUM' },
            new Map<String, Decimal>{ 'FlexCredits' => 1000 });
        registerEnt();

        Test.startTest();
        Messaging.SingleEmailMessage msg =
            DigitalWalletConsumptionService.buildSummaryEmail(new List<String>{ 'me@example.com' });
        Test.stopTest();

        Assert.areEqual(new List<String>{ 'me@example.com' }, msg.getToAddresses());
        Assert.isTrue(msg.getSubject().startsWith('Digital Wallet Consumption'),
            'Subject should describe the report');
        Assert.isTrue(msg.getSubject().contains('(1 card)'),
            'Subject should reflect the single active card');
        Assert.isTrue(msg.getHtmlBody().contains('FlexCredits'),
            'HTML body should list the card');
        Assert.isTrue(msg.getHtmlBody().contains('<table'),
            'HTML body should render a table');
        Assert.isTrue(msg.getPlainTextBody().contains('FlexCredits'),
            'Plain-text body should list the card');
    }

    @IsTest
    static void buildSummaryEmailHandlesNoCards() {
        entRows = new List<SObject>();
        registerEnt();

        Test.startTest();
        Messaging.SingleEmailMessage msg =
            DigitalWalletConsumptionService.buildSummaryEmail(new List<String>{ 'me@example.com' });
        Test.stopTest();

        Assert.isTrue(msg.getSubject().contains('(0 cards)'),
            'Subject should reflect zero active cards');
        Assert.isTrue(msg.getHtmlBody().contains('No active entitlements'),
            'HTML body should note the empty result');
        Assert.isTrue(msg.getPlainTextBody().contains('No active entitlements'),
            'Plain-text body should note the empty result');
    }

    @IsTest
    static void emailSummaryOverloadsRunCleanly() {
        entRows = new List<SObject>{ ent('FlexCredits', 400000, T_START, T_END) };
        injectConsumption(
            new Map<String, String>{ 'FlexCredits' => 'SUM' },
            new Map<String, Decimal>{ 'FlexCredits' => 1000 });
        registerEnt();

        Test.startTest();
        try {
            // Explicit recipients path.
            DigitalWalletConsumptionService.emailSummary(new List<String>{ 'me@example.com' });
            // No-arg overload -> defaults to the running user.
            DigitalWalletConsumptionService.emailSummary();
        } catch (Exception e) {
            Assert.fail('emailSummary overloads should not throw: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @IsTest
    static void numberFormattingIsClean() {
        Assert.areEqual('', DigitalWalletConsumptionService.fmtNum(null));
        Assert.areEqual('36', DigitalWalletConsumptionService.fmtNum(36.000000),
            'Whole numbers should drop the decimal');
        Assert.areEqual('8296.90', DigitalWalletConsumptionService.fmtNum(8296.903391),
            'Precision artifacts should round to two places');
        Assert.areEqual('14751.03', DigitalWalletConsumptionService.fmtNum(14751.034118),
            'Two-decimal values are preserved');
    }

    @IsTest
    static void emailSummaryDefaultsToRunningUser() {
        entRows = new List<SObject>{ ent('FlexCredits', 400000, T_START, T_END) };
        injectConsumption(
            new Map<String, String>{ 'FlexCredits' => 'SUM' },
            new Map<String, Decimal>{ 'FlexCredits' => 1000 });
        registerEnt();

        Test.startTest();
        // Null recipients => running user's email. Apex suppresses real sends in
        // tests, so assert the path runs cleanly.
        try {
            DigitalWalletConsumptionService.emailSummary(null);
        } catch (Exception e) {
            Assert.fail('emailSummary should not throw: ' + e.getMessage());
        }
        Test.stopTest();
    }
}
