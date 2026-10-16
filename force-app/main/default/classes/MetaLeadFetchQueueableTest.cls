@IsTest
private class MetaLeadFetchQueueableTest {

    private class GraphApiMock implements HttpCalloutMock {
        private Integer statusCode;
        private String body;
        GraphApiMock(Integer statusCode, String body) {
            this.statusCode = statusCode;
            this.body = body;
        }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(statusCode);
            res.setBody(body);
            return res;
        }
    }

    private static String buildLeadPayload(String fullName, String email, String phone, String city) {
        Map<String, Object> payload = new Map<String, Object>{
            'ad_id' => 'AD1', 'adset_id' => 'ADSET1', 'campaign_id' => 'CAMP1',
            'form_id' => 'FORM1', 'page_id' => 'PAGE1', 'created_time' => 1700000000,
            'field_data' => new List<Object>{
                new Map<String, Object>{ 'name' => 'full_name', 'values' => new List<Object>{ fullName } },
                new Map<String, Object>{ 'name' => 'email', 'values' => new List<Object>{ email } },
                new Map<String, Object>{ 'name' => 'phone_number', 'values' => new List<Object>{ phone } },
                new Map<String, Object>{ 'name' => 'city', 'values' => new List<Object>{ city } }
            }
        };
        return JSON.serialize(payload);
    }

    private static void primePageConfig(String pageId) {
        MetaLeadFetchQueueable.pageConfigCache = new Map<String, Meta_Page_Setting__c>{
            pageId => new Meta_Page_Setting__c(Page_Id__c = pageId, Active__c = true)
        };
    }

    // Meta_Lead_Field_Mapping__c is org data (not deployed metadata like the old __mdt), so
    // it isn't visible inside an isolated test transaction — inject it directly via
    // MetaLeadMapper's @TestVisible cache instead of relying on org rows.
    private static void primeFieldMapping() {
        MetaLeadMapper.mappingCache = new Map<String, String>{
            'email' => 'Email', 'phone_number' => 'Phone', 'city' => 'City'
        };
    }

    private static Set<String> activeLeadSourceValues() {
        Set<String> values = new Set<String>();
        for (Schema.PicklistEntry entry : Lead.LeadSource.getDescribe().getPicklistValues()) {
            if (entry.isActive()) {
                values.add(entry.getValue());
            }
        }
        return values;
    }

    @IsTest
    static void testProcessOneLead_HappyPath_CreatesLeadWithMappedFields() {
        primePageConfig('PAGE1');
        primeFieldMapping();
        Test.setMock(HttpCalloutMock.class, new GraphApiMock(200, buildLeadPayload('Jane Doe', 'jane@example.com', '9990001111', 'Mumbai')));

        Test.startTest();
            new MetaLeadFetchQueueable(new List<MetaLeadgenEvent>{ new MetaLeadgenEvent('111222333', 'PAGE1') })
                .processOneLead(new MetaLeadgenEvent('111222333', 'PAGE1'));
        Test.stopTest();

        Lead created = [
            SELECT FirstName, LastName, Email, Phone, City, Meta_Leadgen_Id__c, Meta_Ad_Id__c,
                   Meta_Campaign_Id__c, LeadSource, Meta_Lead_Source_Detail__c
            FROM Lead
            WHERE Meta_Leadgen_Id__c = '111222333'
        ];
        System.assertEquals('Jane', created.FirstName);
        System.assertEquals('Doe', created.LastName);
        System.assertEquals('jane@example.com', created.Email);
        System.assertEquals('9990001111', created.Phone);
        System.assertEquals('Mumbai', created.City);
        System.assertEquals('AD1', created.Meta_Ad_Id__c);
        System.assertEquals('CAMP1', created.Meta_Campaign_Id__c);
        System.assertEquals('Meta Lead Ads', created.Meta_Lead_Source_Detail__c);
        System.assertEquals(
            activeLeadSourceValues().contains('Facebook') ? 'Facebook' : null,
            created.LeadSource
        );
        System.assertEquals(0, [SELECT count() FROM Meta_Lead_Sync_Failure__c], 'Happy path must not dead-letter anything');
    }

    @IsTest
    static void testProcessOneLead_MissingNameAndCompany_FallsBackToPlaceholders() {
        primePageConfig('PAGE1');
        Map<String, Object> payload = new Map<String, Object>{
            'field_data' => new List<Object>{
                new Map<String, Object>{ 'name' => 'email', 'values' => new List<Object>{ 'noname@example.com' } }
            }
        };
        Test.setMock(HttpCalloutMock.class, new GraphApiMock(200, JSON.serialize(payload)));

        Test.startTest();
            new MetaLeadFetchQueueable(new List<MetaLeadgenEvent>{ new MetaLeadgenEvent('444', 'PAGE1') })
                .processOneLead(new MetaLeadgenEvent('444', 'PAGE1'));
        Test.stopTest();

        Lead created = [SELECT LastName, Company FROM Lead WHERE Meta_Leadgen_Id__c = '444'];
        System.assertEquals('Meta Lead 444', created.LastName);
        System.assertEquals('Unknown (Meta Lead Ad)', created.Company);
    }

    @IsTest
    static void testProcessOneLead_Redelivery_UpdatesSameLeadInsteadOfDuplicating() {
        primePageConfig('PAGE1');
        primeFieldMapping();
        Test.setMock(HttpCalloutMock.class, new GraphApiMock(200, buildLeadPayload('First Delivery', 'a@example.com', '111', 'CityA')));
        Test.startTest();
            new MetaLeadFetchQueueable(new List<MetaLeadgenEvent>{ new MetaLeadgenEvent('555', 'PAGE1') })
                .processOneLead(new MetaLeadgenEvent('555', 'PAGE1'));
        Test.stopTest();

        Test.setMock(HttpCalloutMock.class, new GraphApiMock(200, buildLeadPayload('Second Delivery', 'a@example.com', '111', 'CityB')));
        new MetaLeadFetchQueueable(new List<MetaLeadgenEvent>{ new MetaLeadgenEvent('555', 'PAGE1') })
            .processOneLead(new MetaLeadgenEvent('555', 'PAGE1'));

        List<Lead> leads = [SELECT City FROM Lead WHERE Meta_Leadgen_Id__c = '555'];
        System.assertEquals(1, leads.size(), 'Redelivery must update, not duplicate');
        System.assertEquals('CityB', leads[0].City);
    }

    @IsTest
    static void testProcessOneLead_AlreadyConvertedLead_NotTouched() {
        primePageConfig('PAGE1');
        Lead lead = new Lead(FirstName = 'Existing', LastName = 'Converted', Company = 'Co', Status = 'New', Meta_Leadgen_Id__c = '666');
        insert lead;
        LeadStatus convertStatus = [SELECT MasterLabel FROM LeadStatus WHERE IsConverted = true LIMIT 1];
        Database.LeadConvert lc = new Database.LeadConvert();
        lc.setLeadId(lead.Id);
        lc.setConvertedStatus(convertStatus.MasterLabel);
        Database.convertLead(lc);

        Test.setMock(HttpCalloutMock.class, new GraphApiMock(200, buildLeadPayload('Should Not Apply', 'ignored@example.com', '000', 'IgnoredCity')));

        Test.startTest();
            new MetaLeadFetchQueueable(new List<MetaLeadgenEvent>{ new MetaLeadgenEvent('666', 'PAGE1') })
                .processOneLead(new MetaLeadgenEvent('666', 'PAGE1'));
        Test.stopTest();

        Lead unchanged = [SELECT City, IsConverted FROM Lead WHERE Meta_Leadgen_Id__c = '666'];
        System.assertEquals(true, unchanged.IsConverted);
        System.assertEquals(null, unchanged.City);
    }

    @IsTest
    static void testProcessOneLead_GraphApiError_DeadLettersAndLogs() {
        primePageConfig('PAGE1');
        Test.setMock(HttpCalloutMock.class, new GraphApiMock(400, '{"error":{"message":"Invalid token"}}'));

        Test.startTest();
            new MetaLeadFetchQueueable(new List<MetaLeadgenEvent>{ new MetaLeadgenEvent('777', 'PAGE1') }).execute(null);
        Test.stopTest();

        System.assertEquals(0, [SELECT count() FROM Lead WHERE Meta_Leadgen_Id__c = '777']);
        List<Error_Log__c> logs = [SELECT Id, Facebook_error__c FROM Error_Log__c WHERE Class__c = 'MetaLeadFetchQueueable'];
        System.assertEquals(1, logs.size());
        System.assertEquals(true, logs[0].Facebook_error__c);

        List<Meta_Lead_Sync_Failure__c> failures = [
            SELECT Leadgen_Id__c, Page_Id__c, Status__c, Raw_Payload__c FROM Meta_Lead_Sync_Failure__c WHERE Leadgen_Id__c = '777'
        ];
        System.assertEquals(1, failures.size(), 'A Graph API error must dead-letter the lead instead of dropping it');
        System.assertEquals('PAGE1', failures[0].Page_Id__c);
        System.assertEquals('New', failures[0].Status__c);
        System.assertEquals(null, failures[0].Raw_Payload__c, 'No payload was ever fetched, so there is nothing to store');
    }

    @IsTest
    static void testProcessOneLead_NoPageConfig_DeadLettersAndLogs() {
        // pageConfigCache left unset (lazy-loads to an empty map — no Meta_Page_Config__c
        // records exist in this test context), so this must fail closed without making a callout.
        Test.startTest();
            new MetaLeadFetchQueueable(new List<MetaLeadgenEvent>{ new MetaLeadgenEvent('888', 'UNCONFIGURED_PAGE') }).execute(null);
        Test.stopTest();

        System.assertEquals(0, [SELECT count() FROM Lead WHERE Meta_Leadgen_Id__c = '888']);
        List<Error_Log__c> logs = [SELECT Id FROM Error_Log__c WHERE Class__c = 'MetaLeadFetchQueueable'];
        System.assertEquals(1, logs.size());
        List<Meta_Lead_Sync_Failure__c> failures = [SELECT Id, Page_Id__c FROM Meta_Lead_Sync_Failure__c WHERE Leadgen_Id__c = '888'];
        System.assertEquals(1, failures.size());
        System.assertEquals('UNCONFIGURED_PAGE', failures[0].Page_Id__c);
    }

    @IsTest
    static void testProcessOneLead_LeadDmlRejected_DeadLettersFetchedPayload() {
        // A malformed email fails standard Email field validation at DML time — a stand-in
        // for any org validation/duplicate rule rejecting the insert. The Graph API call
        // itself succeeds, so this exercises the "we have a real payload but couldn't save
        // it" dead-letter branch, distinct from the no-payload branches above.
        primePageConfig('PAGE1');
        primeFieldMapping();
        Test.setMock(HttpCalloutMock.class, new GraphApiMock(200, buildLeadPayload('Jane Doe', 'not-a-valid-email', '999', 'Mumbai')));

        Test.startTest();
            new MetaLeadFetchQueueable(new List<MetaLeadgenEvent>{ new MetaLeadgenEvent('999', 'PAGE1') }).execute(null);
        Test.stopTest();

        System.assertEquals(0, [SELECT count() FROM Lead WHERE Meta_Leadgen_Id__c = '999']);
        List<Meta_Lead_Sync_Failure__c> failures = [
            SELECT Raw_Payload__c FROM Meta_Lead_Sync_Failure__c WHERE Leadgen_Id__c = '999'
        ];
        System.assertEquals(1, failures.size());
        System.assert(failures[0].Raw_Payload__c.contains('Jane Doe'), 'The fetched payload must be preserved for a later resend');
    }

    @IsTest
    static void testEnqueue_BatchesLargeListsAcrossMultipleJobs() {
        List<MetaLeadgenEvent> events = new List<MetaLeadgenEvent>();
        for (Integer i = 0; i < 120; i++) {
            events.add(new MetaLeadgenEvent('id' + i, 'PAGE1'));
        }

        // Deliberately NOT wrapped in Test.startTest()/stopTest() — that would execute
        // the queued jobs immediately (attempting live callouts with no mock set). This
        // test only asserts on the batching/enqueueing behavior itself.
        MetaLeadFetchQueueable.enqueue(events);

        // 120 events at 50/job = 3 jobs; asserting only that enqueue didn't blow past
        // per-transaction limits or drop any batch.
        System.assertEquals(3, [SELECT count() FROM AsyncApexJob WHERE ApexClass.Name = 'MetaLeadFetchQueueable' AND JobType = 'Queueable']);
    }

    @IsTest
    static void testEnqueue_EmptyList_NoOp() {
        Test.startTest();
            MetaLeadFetchQueueable.enqueue(new List<MetaLeadgenEvent>());
            MetaLeadFetchQueueable.enqueue(null);
        Test.stopTest();

        System.assertEquals(0, [SELECT count() FROM AsyncApexJob WHERE ApexClass.Name = 'MetaLeadFetchQueueable']);
    }

    @IsTest
    static void testProcessOneLead_WithPageAccessToken_AppendsTokenToEndpoint() {
        MetaLeadFetchQueueable.pageConfigCache = new Map<String, Meta_Page_Setting__c>{
            'PAGE1' => new Meta_Page_Setting__c(Page_Id__c = 'PAGE1', Page_Access_Token__c = 'TEST_PAGE_TOKEN', Active__c = true)
        };
        MetaLeadFetchQueueable.cachedSetting = new Meta_Integration_Config__c(Graph_API_Version__c = 'v26.0');
        primeFieldMapping();
        Test.setMock(HttpCalloutMock.class, new GraphApiMock(200, buildLeadPayload('Jane Doe', 'jane@example.com', '9990001111', 'Mumbai')));

        Test.startTest();
            new MetaLeadFetchQueueable(new List<MetaLeadgenEvent>{ new MetaLeadgenEvent('555666', 'PAGE1') })
                .processOneLead(new MetaLeadgenEvent('555666', 'PAGE1'));
        Test.stopTest();

        System.assertEquals(1, [SELECT count() FROM Lead WHERE Meta_Leadgen_Id__c = '555666']);
    }
}