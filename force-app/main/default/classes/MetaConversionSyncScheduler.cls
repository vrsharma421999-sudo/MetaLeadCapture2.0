/**
 * @class        MetaConversionSyncScheduler
 * @description  Scheduled entry point for outbound Meta Conversions API sync. Meta's own
 *               guidance for CRM integrations is that real-time is ideal but hourly/daily
 *               batching is acceptable as long as full stage history is reported — so rather
 *               than requiring every Lead-editing profile to have Named Credential/token
 *               access for a real-time callout, this runs on a schedule as a single service
 *               account and picks up whatever LeadConversionSyncHandler has queued since the
 *               last run (plus any Failed rows still under the retry limit).
 *
 *               Not scheduled by default — an admin (or a post-deploy script) calls
 *               scheduleHourly()/scheduleDaily() once. Re-running either is safe: it aborts
 *               any existing job under the same name first.
 */
public without sharing class MetaConversionSyncScheduler implements Schedulable {
    public static final String HOURLY_JOB_NAME = 'Meta Conversion Sync - Hourly';
    public static final String DAILY_JOB_NAME = 'Meta Conversion Sync - Daily';

    public void execute(SchedulableContext sc) {
        System.enqueueJob(new MetaConversionSyncQueueable());
    }

    public static Id scheduleHourly() {
        abortExisting(HOURLY_JOB_NAME);
        // Every hour, on the hour.
        return System.schedule(HOURLY_JOB_NAME, '0 0 * * * ?', new MetaConversionSyncScheduler());
    }

    public static Id scheduleDaily(Integer hourOfDay) {
        abortExisting(DAILY_JOB_NAME);
        String cron = '0 0 ' + hourOfDay + ' * * ?';
        return System.schedule(DAILY_JOB_NAME, cron, new MetaConversionSyncScheduler());
    }

    private static void abortExisting(String jobName) {
        for (CronTrigger ct : [
            SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = :jobName LIMIT 1
        ]) {
            System.abortJob(ct.Id);
        }
    }
}