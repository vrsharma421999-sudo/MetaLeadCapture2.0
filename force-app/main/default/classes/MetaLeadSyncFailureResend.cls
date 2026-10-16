/**
 * @class        MetaLeadSyncFailureResend
 * @description  Lets an admin retry a dead-lettered Meta lead (Meta_Lead_Sync_Failure__c)
 *               once the underlying problem is fixed — a missing/incorrect
 *               Meta_Page_Config__c record, an org validation/duplicate rule, a bad field
 *               mapping — without needing Meta to redeliver the webhook (Meta only retries
 *               undelivered webhooks for a limited window).
 *
 *               Exposed as an @InvocableMethod so it can be wired to a Quick Action / Flow
 *               button on the Meta Lead Sync Failure page layout (point-and-click, no further
 *               Apex needed) as well as called directly, e.g. from Execute Anonymous for a
 *               bulk retry.
 *
 *               If the failure already has a Raw_Payload__c (the Graph API call succeeded but
 *               the Lead upsert didn't), that stored payload is reused directly — no new
 *               callout. If it doesn't (the callout itself failed, e.g. Page wasn't
 *               configured yet), a fresh Graph API call is made via
 *               MetaLeadFetchQueueable.fetchPayload using whatever Page config exists now.
 */
public without sharing class MetaLeadSyncFailureResend {

    @InvocableMethod(
        label='Resend Meta Lead Sync Failure'
        description='Re-attempts saving a dead-lettered Meta lead as a Lead record. Marks it Resolved on success, or increments Attempts and keeps it open on failure.'
        category='Meta Lead Ads'
    )
    public static List<ResendResult> resend(List<Id> failureIds) {
        List<ResendResult> results = new List<ResendResult>();
        if (failureIds == null || failureIds.isEmpty()) {
            return results;
        }

        Map<Id, Meta_Lead_Sync_Failure__c> failures = new Map<Id, Meta_Lead_Sync_Failure__c>([
            SELECT Id, Leadgen_Id__c, Page_Id__c, Raw_Payload__c, Attempts__c, Status__c
            FROM Meta_Lead_Sync_Failure__c
            WHERE Id IN :failureIds
        ]);

        List<Meta_Lead_Sync_Failure__c> toUpdate = new List<Meta_Lead_Sync_Failure__c>();
        for (Id failureId : failureIds) {
            Meta_Lead_Sync_Failure__c failure = failures.get(failureId);
            if (failure == null) {
                results.add(new ResendResult(failureId, false, 'Meta_Lead_Sync_Failure__c record not found.'));
                continue;
            }
            results.add(resendOne(failure, toUpdate));
        }

        if (!toUpdate.isEmpty()) {
            Database.update(toUpdate, AccessLevel.SYSTEM_MODE);
        }
        return results;
    }

    private static ResendResult resendOne(Meta_Lead_Sync_Failure__c failure, List<Meta_Lead_Sync_Failure__c> toUpdate) {
        System.debug(LoggingLevel.INFO, '[MetaLeadSyncFailureResend] retrying ' + failure.Id + ' (leadgen_id=' + failure.Leadgen_Id__c
            + ', hasStoredPayload=' + String.isNotBlank(failure.Raw_Payload__c) + ')');
        try {
            Map<String, Object> payload = String.isNotBlank(failure.Raw_Payload__c)
                ? (Map<String, Object>) JSON.deserializeUntyped(failure.Raw_Payload__c)
                : MetaLeadFetchQueueable.fetchPayload(failure.Leadgen_Id__c, failure.Page_Id__c);

            Lead resolvedLead = MetaLeadMapper.upsertLeadFromPayload(failure.Leadgen_Id__c, payload);
            System.debug(LoggingLevel.INFO, '[MetaLeadSyncFailureResend] ' + failure.Id + ' RESOLVED -> Lead ' + resolvedLead.Id);

            toUpdate.add(new Meta_Lead_Sync_Failure__c(
                Id = failure.Id,
                Status__c = 'Resolved',
                Resolved_Lead__c = resolvedLead.Id,
                Attempts__c = (failure.Attempts__c == null ? 0 : failure.Attempts__c) + 1,
                Last_Attempt__c = System.now()
            ));
            return new ResendResult(failure.Id, true, 'Resolved — Lead ' + resolvedLead.Id);
        } catch (Exception e) {
            String reason = e.getMessage() + ' (' + e.getTypeName() + ')';
            System.debug(LoggingLevel.WARN, '[MetaLeadSyncFailureResend] ' + failure.Id + ' still failing: ' + reason);
            toUpdate.add(new Meta_Lead_Sync_Failure__c(
                Id = failure.Id,
                Status__c = 'Retrying',
                Failure_Reason__c = reason,
                Attempts__c = (failure.Attempts__c == null ? 0 : failure.Attempts__c) + 1,
                Last_Attempt__c = System.now()
            ));
            CreateErrorLog.logFacebookError(
                'resendOne', 'MetaLeadSyncFailureResend', 'Meta_Lead_Sync_Failure__c ' + failure.Id, e,
                failure.Page_Id__c, null, null, 'Resend attempt failed for leadgen_id ' + failure.Leadgen_Id__c
            );
            return new ResendResult(failure.Id, false, reason);
        }
    }

    public class ResendResult {
        @InvocableVariable public Id failureId;
        @InvocableVariable public Boolean success;
        @InvocableVariable public String message;

        public ResendResult(Id failureId, Boolean success, String message) {
            this.failureId = failureId;
            this.success = success;
            this.message = message;
        }
    }
}