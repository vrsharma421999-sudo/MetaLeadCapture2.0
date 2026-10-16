@IsTest
private class MetaConversionSyncSchedulerTest {

    @IsTest
    static void testScheduleHourly_CreatesCronJob() {
        Test.startTest();
            Id jobId = MetaConversionSyncScheduler.scheduleHourly();
        Test.stopTest();

        System.assertNotEquals(null, jobId);
        List<CronTrigger> jobs = [SELECT Id, CronJobDetail.Name FROM CronTrigger WHERE Id = :jobId];
        System.assertEquals(1, jobs.size());
        System.assertEquals(MetaConversionSyncScheduler.HOURLY_JOB_NAME, jobs[0].CronJobDetail.Name);
    }

    @IsTest
    static void testScheduleHourly_CalledTwice_AbortsPreviousJob() {
        Test.startTest();
            Id firstJobId = MetaConversionSyncScheduler.scheduleHourly();
            Id secondJobId = MetaConversionSyncScheduler.scheduleHourly();
        Test.stopTest();

        System.assertNotEquals(firstJobId, secondJobId);
        System.assertEquals(1, [
            SELECT count() FROM CronTrigger WHERE CronJobDetail.Name = :MetaConversionSyncScheduler.HOURLY_JOB_NAME
        ]);
    }

    @IsTest
    static void testScheduleDaily_CreatesCronJob() {
        Test.startTest();
            Id jobId = MetaConversionSyncScheduler.scheduleDaily(2);
        Test.stopTest();

        System.assertNotEquals(null, jobId);
        System.assertEquals(1, [
            SELECT count() FROM CronTrigger WHERE CronJobDetail.Name = :MetaConversionSyncScheduler.DAILY_JOB_NAME
        ]);
    }

    @IsTest
    static void testExecute_EnqueuesSyncJob() {
        Test.startTest();
            new MetaConversionSyncScheduler().execute(null);
        Test.stopTest();

        System.assertEquals(1, [
            SELECT count() FROM AsyncApexJob WHERE ApexClass.Name = 'MetaConversionSyncQueueable' AND JobType = 'Queueable'
        ]);
    }
}