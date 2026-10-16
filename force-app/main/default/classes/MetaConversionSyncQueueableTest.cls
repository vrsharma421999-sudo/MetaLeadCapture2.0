@IsTest
private class MetaConversionSyncQueueableTest {

    private class CapiMock implements HttpCalloutMock {
        private Integer statusCode;
        private String body;
        CapiMock(Integer statusCode, String body) {
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

    private static void primeSetting() {
        MetaConversionSyncQueueable.cachedSetting = new Meta_Integration_Config__c(
            Dataset_ID__c = 'DATASET1',
            Lead_Event_Source__c = 'Salesforce',
            Graph_API_Version__c = 'v21.0',
            Max_Conversion_Sync_Attempts__c = 5
        );
    }

    private static Lead insertLead(String leadgenId) {
        Lead lead = new Lead(FirstName = 'T', LastName = 'L', Company = 'Co', Status = 'Open - Not Contacted', Meta_Leadgen_Id__c = leadgenId);
        insert lead;
        return lead;
    }

    private static Meta_Conversion_Event__c insertPendingEvent(Id leadId, String leadgenId) {
        Meta_Conversion_Event__c evt = new Meta_Conversion_Event__c(
            Lead__c = leadId, Leadgen_Id__c = leadgenId, Event_Name__c = 'qualified_lead',
            Event_Time__c = System.now(), Status__c = 'Pending', Attempts__c = 0
        );
        insert evt;
        return evt;
    }

    @IsTest
    static void testExecute_Success_MarksEventsSent() {
        primeSetting();
        Lead lead = insertLead('LG-201');
        Meta_Conversion_Event__c evt = insertPendingEvent(lead.Id, 'LG-201');
        Test.setMock(HttpCalloutMock.class, new CapiMock(200, '{"events_received":1,"messages":[],"fbtrace_id":"abc"}'));

        Test.startTest();
            new MetaConversionSyncQueueable().execute(null);
        Test.stopTest();

        Meta_Conversion_Event__c updated = [SELECT Status__c, Attempts__c, Response__c FROM Meta_Conversion_Event__c WHERE Id = :evt.Id];
        System.assertEquals('Sent', updated.Status__c);
        System.assertEquals(1, updated.Attempts__c);
        System.assert(updated.Response__c.contains('events_received'));
    }

    @IsTest
    static void testExecute_ApiError_MarksEventsFailedAndLogs() {
        primeSetting();
        Lead lead = insertLead('LG-202');
        Meta_Conversion_Event__c evt = insertPendingEvent(lead.Id, 'LG-202');
        Test.setMock(HttpCalloutMock.class, new CapiMock(400, '{"error":{"message":"Invalid parameter"}}'));

        Test.startTest();
            new MetaConversionSyncQueueable().execute(null);
        Test.stopTest();

        Meta_Conversion_Event__c updated = [SELECT Status__c, Attempts__c FROM Meta_Conversion_Event__c WHERE Id = :evt.Id];
        System.assertEquals('Failed', updated.Status__c);
        System.assertEquals(1, updated.Attempts__c);
        System.assertEquals(1, [SELECT count() FROM Error_Log__c WHERE Class__c = 'MetaConversionSyncQueueable']);
    }

    @IsTest
    static void testExecute_NotConfigured_SkipsWithoutCallout() {
        // cachedSetting left null; no Meta_Integration_Setting__c row exists in this test
        // context, so this must no-op rather than attempt a callout (no mock is registered —
        // an attempted callout would throw and fail this test).
        Lead lead = insertLead('LG-203');
        Meta_Conversion_Event__c evt = insertPendingEvent(lead.Id, 'LG-203');

        Test.startTest();
            new MetaConversionSyncQueueable().execute(null);
        Test.stopTest();

        Meta_Conversion_Event__c unchanged = [SELECT Status__c, Attempts__c FROM Meta_Conversion_Event__c WHERE Id = :evt.Id];
        System.assertEquals('Pending', unchanged.Status__c);
        System.assertEquals(0, unchanged.Attempts__c);
    }

    @IsTest
    static void testExecute_NoPendingEvents_NoOp() {
        primeSetting();
        Test.startTest();
            new MetaConversionSyncQueueable().execute(null);
        Test.stopTest();
        System.assert(true, 'Completes without error when there is nothing to send');
    }

    @IsTest
    static void testExecute_AttemptsAtMax_ExcludedFromBatch() {
        primeSetting();
        Lead lead = insertLead('LG-204');
        Meta_Conversion_Event__c evt = new Meta_Conversion_Event__c(
            Lead__c = lead.Id, Leadgen_Id__c = 'LG-204', Event_Name__c = 'qualified_lead',
            Event_Time__c = System.now(), Status__c = 'Failed', Attempts__c = 5
        );
        insert evt;
        // No mock set — if the (already-exhausted) event were picked up, the callout would
        // throw and fail this test.

        Test.startTest();
            new MetaConversionSyncQueueable().execute(null);
        Test.stopTest();

        Meta_Conversion_Event__c unchanged = [SELECT Status__c, Attempts__c FROM Meta_Conversion_Event__c WHERE Id = :evt.Id];
        System.assertEquals('Failed', unchanged.Status__c);
        System.assertEquals(5, unchanged.Attempts__c);
    }
}