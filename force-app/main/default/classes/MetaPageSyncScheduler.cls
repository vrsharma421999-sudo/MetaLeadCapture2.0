/**
 * @class        MetaPageSyncScheduler
 * @description  Runs MetaPageSyncService on a schedule (recommended: daily) so a newly
 *               connected Facebook Page is auto-subscribed and auto-configured without any
 *               manual Salesforce-side setup, as long as the Meta System User has been
 *               granted access to it in Business Manager.
 */
public class MetaPageSyncScheduler implements Schedulable {
    public void execute(SchedulableContext sc) {
        MetaPageSyncQueueable.enqueue();
    }

    public static String scheduleDaily() {
        return System.schedule('Meta Page Sync - Daily', '0 15 2 * * ?', new MetaPageSyncScheduler());
    }
}