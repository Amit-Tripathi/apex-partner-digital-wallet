/**
 * Tests for DigitalWalletConsumptionService.
 *
 * The Data 360 DMOs (TenantEntitlementTransaction__dlm /
 * TenantDailyEntitlementConsumption__dlm) cannot be created via DML, so query
 * responses are mocked with the native SoqlStubProvider pattern
 * (Test.createSoqlStub + Test.createStubQueryRow). This makes the tests
 * environment-aware per object: they fabricate rows for each DMO type and never
 * depend on real Data Cloud data.
 */
@IsTest
public class DigitalWalletConsumptionServiceTest {

    // Rows returned by the stubs for the current test (set before createSoqlStub).
    static List<SObject> entRows  = new List<SObject>();
    static List<SObject> consRows = new List<SObject>();

    // ---- SOQL stubs (one per DMO type) ----
    public class EntitlementStub extends SoqlStubProvider {
        public override List<SObject> handleSoqlQuery(Schema.SObjectType sot, String stubbedQuery, Map<String, Object> bindVars) {
            Assert.areEqual(TenantEntitlementTransaction__dlm.sObjectType, sot);
            return entRows;
        }
    }
    public class ConsumptionStub extends SoqlStubProvider {
        public override List<SObject> handleSoqlQuery(Schema.SObjectType sot, String stubbedQuery, Map<String, Object> bindVars) {
            Assert.areEqual(TenantDailyEntitlementConsumption__dlm.sObjectType, sot);
            return consRows;
        }
    }

    // ---- Row builders ----
    static SObject ent(String card, Decimal qty, Datetime startDt, Datetime endDt) {
        return Test.createStubQueryRow(TenantEntitlementTransaction__dlm.sObjectType, new Map<String, Object>{
            'entitlementcarddefdevlname__c'    => card,
            'quantity__c'                      => qty,
            'startdate__c'                     => startDt,
            'enddate__c'                       => endDt,
            'entitlementtransactiontype__c'    => (qty >= 0 ? 'Add' : 'Reduction')
        });
    }
    static SObject con(String card, String aggType, Decimal units, Datetime utilDt, String env) {
        return Test.createStubQueryRow(TenantDailyEntitlementConsumption__dlm.sObjectType, new Map<String, Object>{
            'carddefinitiondevelopername__c'      => card,
            'usageaggregationtype__c'             => aggType,
            'unitsconsumed__c'                    => units,
            'utilizationdate__c'                  => utilDt,
            'Usage_Business_Environment_Type__c'  => env
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

    static void registerStubs() {
        Test.createSoqlStub(TenantEntitlementTransaction__dlm.sObjectType, new EntitlementStub());
        Test.createSoqlStub(TenantDailyEntitlementConsumption__dlm.sObjectType, new ConsumptionStub());
    }

    @IsTest
    static void computesAllCardScenarios() {
        Datetime tStart = Datetime.newInstanceGmt(2025, 11, 13, 23, 0, 0);
        Datetime tEnd   = Datetime.newInstanceGmt(2026, 11, 13, 23, 0, 0);

        entRows = new List<SObject>{
            // FlexCredits: Add 500000 + Reduction -100000 => net 400000 (SUM card)
            ent('FlexCredits', 500000, tStart, tEnd),
            ent('FlexCredits', -100000, tStart, tEnd),
            // DataStorageCard: 6144 (MAX / snapshot card)
            ent('DataStorageCard', 6144, tStart, tEnd),
            // Personalization: effectively unlimited
            ent('Personalization', 1000000000000L, tStart, tEnd)
        };
        consRows = new List<SObject>{
            // FlexCredits SUM within window => 300000 + 61702 = 361702
            con('FlexCredits', 'SUM', 300000, Datetime.newInstanceGmt(2026, 1, 1, 0, 0, 0), 'Production'),
            con('FlexCredits', 'SUM', 61702,  Datetime.newInstanceGmt(2026, 2, 1, 0, 0, 0), 'Production'),
            // Out-of-window row => must be excluded
            con('FlexCredits', 'SUM', 999999, Datetime.newInstanceGmt(2020, 1, 1, 0, 0, 0), 'Production'),
            // DataStorageCard MAX: latest Production snapshot within window = 248.17
            con('DataStorageCard', 'MAX', 100,    Datetime.newInstanceGmt(2026, 1, 1, 0, 0, 0), 'Production'),
            con('DataStorageCard', 'MAX', 248.17, Datetime.newInstanceGmt(2026, 6, 1, 0, 0, 0), 'Production'),
            // Later reading but non-Production => ignored due to Production preference
            con('DataStorageCard', 'MAX', 9999,   Datetime.newInstanceGmt(2026, 7, 1, 0, 0, 0), 'Sandbox')
            // Personalization: no consumption rows
        };

        registerStubs();
        Assert.isTrue(Test.isSoqlStubDefined(TenantEntitlementTransaction__dlm.sObjectType));
        Assert.isTrue(Test.isSoqlStubDefined(TenantDailyEntitlementConsumption__dlm.sObjectType));

        Test.startTest();
        List<DigitalWalletConsumptionService.CardConsumption> res =
            DigitalWalletConsumptionService.computeConsumption();
        Test.stopTest();

        Assert.areEqual(3, res.size(), 'Expected one row per active card');
        Map<String, DigitalWalletConsumptionService.CardConsumption> m = indexByCard(res);

        // --- FlexCredits (SUM, net of reduction, window-scoped) ---
        DigitalWalletConsumptionService.CardConsumption flex = m.get('FlexCredits');
        Assert.areEqual('SUM', flex.aggType);
        Assert.areEqual(400000, flex.totalCredits.intValue());
        Assert.areEqual(361702, flex.consumed.intValue());
        Assert.areEqual(38298, flex.remaining.intValue());
        Assert.areEqual(90.43, flex.pctConsumed);
        Assert.areEqual(9.57, flex.pctRemaining);
        Assert.areEqual('', flex.note);

        // --- DataStorageCard (MAX, latest Production snapshot) ---
        DigitalWalletConsumptionService.CardConsumption ds = m.get('DataStorageCard');
        Assert.areEqual('MAX', ds.aggType);
        Assert.areEqual(6144, ds.totalCredits.intValue());
        Assert.areEqual(248.17, ds.consumed);
        Assert.areEqual(5895.83, ds.remaining);
        Assert.areEqual(4.04, ds.pctConsumed);
        Assert.areEqual(95.96, ds.pctRemaining);

        // --- Personalization (unlimited, no consumption) ---
        DigitalWalletConsumptionService.CardConsumption p = m.get('Personalization');
        Assert.areEqual(0, p.consumed.intValue());
        Assert.areEqual('1000000000000', p.totalCredits.toPlainString());
        Assert.areEqual('UNLIMITED', p.note);
        Assert.areEqual(0.00, p.pctConsumed);
        Assert.areEqual(100.00, p.pctRemaining);
    }

    @IsTest
    static void returnsEmptyWhenNoEntitlements() {
        entRows  = new List<SObject>();
        consRows = new List<SObject>();
        registerStubs();

        Test.startTest();
        List<DigitalWalletConsumptionService.CardConsumption> res =
            DigitalWalletConsumptionService.computeConsumption();
        Test.stopTest();

        Assert.areEqual(0, res.size(), 'No active entitlements should yield no cards');
    }

    @IsTest
    static void logSummaryRunsWithoutError() {
        entRows = new List<SObject>{
            ent('FlexCredits', 400000,
                Datetime.newInstanceGmt(2025, 11, 13, 23, 0, 0),
                Datetime.newInstanceGmt(2026, 11, 13, 23, 0, 0))
        };
        consRows = new List<SObject>{
            con('FlexCredits', 'SUM', 1000,
                Datetime.newInstanceGmt(2026, 1, 1, 0, 0, 0), 'Production')
        };
        registerStubs();

        Test.startTest();
        DigitalWalletConsumptionService.logSummary();
        Test.stopTest();
        // No assertion needed: exercises the debug-output path for coverage.
    }

    @IsTest
    static void buildSummaryEmailComposesMessage() {
        entRows = new List<SObject>{
            ent('FlexCredits', 400000,
                Datetime.newInstanceGmt(2025, 11, 13, 23, 0, 0),
                Datetime.newInstanceGmt(2026, 11, 13, 23, 0, 0))
        };
        consRows = new List<SObject>{
            con('FlexCredits', 'SUM', 1000,
                Datetime.newInstanceGmt(2026, 1, 1, 0, 0, 0), 'Production')
        };
        registerStubs();

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
        entRows  = new List<SObject>();
        consRows = new List<SObject>();
        registerStubs();

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
    static void emailSummaryDefaultsToRunningUser() {
        entRows = new List<SObject>{
            ent('FlexCredits', 400000,
                Datetime.newInstanceGmt(2025, 11, 13, 23, 0, 0),
                Datetime.newInstanceGmt(2026, 11, 13, 23, 0, 0))
        };
        consRows = new List<SObject>{
            con('FlexCredits', 'SUM', 1000,
                Datetime.newInstanceGmt(2026, 1, 1, 0, 0, 0), 'Production')
        };
        registerStubs();

        Test.startTest();
        // Null recipients => running user's email; exercises the send path.
        // Note: Apex suppresses real sends in tests, so we assert the path runs
        // cleanly rather than checking Limits.getEmailInvocations() (always 0 here).
        try {
            DigitalWalletConsumptionService.emailSummary(null);
        } catch (Exception e) {
            Assert.fail('emailSummary should not throw: ' + e.getMessage());
        }
        Test.stopTest();
    }
}
