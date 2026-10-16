@IsTest
private class MetaPageSyncQueueableTest {

    private class EmptyAccountsMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"data":[]}');
            return res;
        }
    }

    @IsTest
    static void testExecute_RunsSyncWithoutError() {
        Test.setMock(HttpCalloutMock.class, new EmptyAccountsMock());

        Test.startTest();
            new MetaPageSyncQueueable().execute(null);
        Test.stopTest();

        System.assert(true, 'Completes without throwing when there are no pages to sync');
    }

    @IsTest
    static void testScheduleDaily_SchedulesJob() {
        Test.startTest();
            String jobId = MetaPageSyncScheduler.scheduleDaily();
        Test.stopTest();

        System.assertNotEquals(null, jobId);
        System.assertEquals(1, [SELECT count() FROM CronTrigger WHERE Id = :jobId]);
    }
}