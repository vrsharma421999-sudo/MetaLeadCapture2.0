/**
 * @class        MetaLeadSyncFailureNotifier
 * @description  Fires whenever Meta_Lead_Sync_Failure__c rows are inserted, so a lead that
 *               couldn't be saved is surfaced immediately rather than depending on someone
 *               remembering to check the "Needs Attention" list view. Recipients and channel
 *               are fully dynamic via Meta_Notification_Recipient__c — one row per User with a
 *               Channel__c of Bell, Email, or Both, managed on the Notifications tab of the
 *               Meta Lead Capture Setup page (replaces the old implicit rule of "every holder
 *               of the Meta_Lead_Integration_Admin permission set gets a bell notification").
 *               Two independent channels fire since neither alone is reliable enough for
 *               "no lead should ever go unnoticed":
 *                - An in-app Custom Notification to every active Meta_Notification_Recipient__c
 *                  whose Channel__c is Bell or Both (only reaches someone who has Salesforce
 *                  open).
 *                - An email to every active Meta_Notification_Recipient__c whose Channel__c is
 *                  Email or Both (that User's User.Email), plus any address listed in
 *                  Meta_Integration_Setting__c.Failure_Notification_Email__c for recipients
 *                  without a Salesforce user (e.g. a shared ops inbox) — works even if nobody
 *                  is logged in.
 *               Both are best-effort: a notification/email failure is swallowed (logged via
 *               debug) rather than allowed to roll back the failure record itself, since the
 *               failure record existing is the important part.
 */
public without sharing class MetaLeadSyncFailureNotifier {

    public static void notify(List<Meta_Lead_Sync_Failure__c> newFailures) {
        if (newFailures == null || newFailures.isEmpty()) {
            return;
        }
        System.debug(LoggingLevel.INFO, '[MetaLeadSyncFailureNotifier.notify] firing for ' + newFailures.size() + ' new failure(s)');
        sendCustomNotification(newFailures);
        sendEmailAlert(newFailures);
    }

    private static void sendCustomNotification(List<Meta_Lead_Sync_Failure__c> failures) {
        try {
            CustomNotificationType notifType = [
                SELECT Id FROM CustomNotificationType
                WHERE DeveloperName = 'Meta_Lead_Sync_Failure_Alert'
                LIMIT 1
            ];
            Set<String> recipientIds = getBellRecipientIds();
            if (recipientIds.isEmpty()) {
                System.debug(LoggingLevel.WARN, '[MetaLeadSyncFailureNotifier.sendCustomNotification] no active Meta_Notification_Recipient__c with Channel__c Bell/Both — nobody to notify in-app. Add one on the Meta Lead Capture Setup page.');
                return;
            }
            System.debug(LoggingLevel.INFO, '[MetaLeadSyncFailureNotifier.sendCustomNotification] notifying ' + recipientIds.size() + ' admin(s)');

            Messaging.CustomNotification notification = new Messaging.CustomNotification();
            Integer count = failures.size();
            notification.setTitle(count == 1 ? 'Meta lead failed to sync' : count + ' Meta leads failed to sync');
            notification.setBody(count == 1
                ? 'Leadgen ' + failures[0].Leadgen_Id__c + ' could not be saved: ' + truncate(failures[0].Failure_Reason__c, 200)
                : 'Open Meta Lead Sync Failures (Needs Attention list view) to review and resend.');
            notification.setNotificationTypeId(notifType.Id);
            notification.setTargetId(failures[0].Id);
            notification.send(recipientIds);
        } catch (Exception ex) {
            System.debug('MetaLeadSyncFailureNotifier: custom notification failed: ' + ex.getMessage());
        }
    }

    private static void sendEmailAlert(List<Meta_Lead_Sync_Failure__c> failures) {
        try {
            Set<String> toAddresses = getEmailRecipientAddresses();
            if (toAddresses.isEmpty()) {
                System.debug(LoggingLevel.INFO, '[MetaLeadSyncFailureNotifier.sendEmailAlert] no email recipients configured — skipping email');
                return;
            }

            Integer count = failures.size();
            System.debug(LoggingLevel.INFO, '[MetaLeadSyncFailureNotifier.sendEmailAlert] sending to ' + toAddresses
                + ' — if your org restricts Email Deliverability (Setup > Deliverability), this call succeeds but nothing arrives');
            Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
            mail.setToAddresses(new List<String>(toAddresses));
            mail.setSubject(count == 1 ? 'Meta lead failed to sync' : count + ' Meta leads failed to sync');
            mail.setPlainTextBody(buildEmailBody(failures));
            mail.setSaveAsActivity(false);
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail });
        } catch (Exception ex) {
            System.debug('MetaLeadSyncFailureNotifier: email alert failed: ' + ex.getMessage());
        }
    }

    private static String buildEmailBody(List<Meta_Lead_Sync_Failure__c> failures) {
        List<String> lines = new List<String>{
            failures.size() + ' Meta lead(s) could not be saved to Salesforce and need review:', ''
        };
        for (Meta_Lead_Sync_Failure__c f : failures) {
            lines.add('- ' + f.Name + ' | leadgen_id=' + f.Leadgen_Id__c + ' | page_id=' + f.Page_Id__c
                + ' | reason: ' + truncate(f.Failure_Reason__c, 300));
        }
        lines.add('');
        lines.add('Review and resend from the Meta Lead Sync Failures "Needs Attention" list view in Salesforce.');
        return String.join(lines, '\n');
    }

    @TestVisible private static List<Meta_Notify_Recipient__c> cachedRecipients;

    private static List<Meta_Notify_Recipient__c> getActiveRecipients() {
        if (cachedRecipients == null) {
            // Meta_Notify_Recipient__c is a Custom Setting: always readable by Apex —
            // including the Guest User whose webhook-triggered dead-letter insert fires this
            // notifier — regardless of sharing/FLS. getAll() (the generated cached accessor)
            // is required for that guest bypass; a plain SOQL SELECT against a Custom Setting
            // does NOT get it.
            cachedRecipients = Meta_Notify_Recipient__c.getAll().values();
        }
        return cachedRecipients;
    }

    private static Set<String> getBellRecipientIds() {
        Set<String> ids = new Set<String>();
        for (Meta_Notify_Recipient__c r : getActiveRecipients()) {
            if (r.Active__c && (r.Channel__c == 'Bell' || r.Channel__c == 'Both') && String.isNotBlank(r.User_Id__c)) {
                ids.add(r.User_Id__c);
            }
        }
        return ids;
    }

    @TestVisible private static Meta_Integration_Config__c cachedSetting;

    private static Set<String> getEmailRecipientAddresses() {
        Set<String> addresses = new Set<String>();
        for (Meta_Notify_Recipient__c r : getActiveRecipients()) {
            if (r.Active__c && (r.Channel__c == 'Email' || r.Channel__c == 'Both') && String.isNotBlank(r.User_Email__c)) {
                addresses.add(r.User_Email__c);
            }
        }

        if (cachedSetting == null) {
            Meta_Integration_Config__c orgDefaults = Meta_Integration_Config__c.getOrgDefaults();
            cachedSetting = (orgDefaults.Id != null) ? orgDefaults : null;
        }
        if (cachedSetting != null && String.isNotBlank(cachedSetting.Failure_Notification_Email__c)) {
            for (String addr : cachedSetting.Failure_Notification_Email__c.split(',')) {
                if (String.isNotBlank(addr)) {
                    addresses.add(addr.trim());
                }
            }
        }
        return addresses;
    }

    private static String truncate(String s, Integer maxLen) {
        if (s == null) {
            return '';
        }
        return s.length() > maxLen ? s.substring(0, maxLen) + '...' : s;
    }
}