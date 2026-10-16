/**
 * @class        MetaPageSyncQueueable
 * @description  Async wrapper around MetaPageSyncService + MetaFormSyncService so both can be
 *               invoked from a Schedulable context (which cannot make callouts directly). Forms
 *               run second, since a newly-discovered Page has to exist as a
 *               Meta_Page_Setting__c row before MetaFormSyncService will scan it for forms.
 */
public without sharing class MetaPageSyncQueueable implements Queueable, Database.AllowsCallouts {
    public void execute(QueueableContext qc) {
        MetaPageSyncService.SyncResult pageResult = MetaPageSyncService.syncPages();
        System.debug(LoggingLevel.INFO, '[MetaPageSyncQueueable] pagesFound=' + pageResult.pagesFound
            + ' pagesAdded=' + pageResult.pagesAdded + ' pagesSubscribeFailed=' + pageResult.pagesSubscribeFailed);

        MetaFormSyncService.SyncResult formResult = MetaFormSyncService.syncForms();
        System.debug(LoggingLevel.INFO, '[MetaPageSyncQueueable] formsFound=' + formResult.formsFound
            + ' questionsFound=' + formResult.questionsFound + ' newMappingsAdded=' + formResult.newMappingsAdded);
    }

    public static void enqueue() {
        if (!Test.isRunningTest()) {
            System.enqueueJob(new MetaPageSyncQueueable());
        }
    }
}