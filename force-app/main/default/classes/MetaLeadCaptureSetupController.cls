/**
 * @class        MetaLeadCaptureSetupController
 * @description  Apex backend for the Meta Lead Capture Setup LWC (metaLeadCaptureSetup) — the
 *               single admin page for everything that used to live in Custom Metadata Types
 *               (Meta_Integration_Setting__c, Meta_Page_Config__c, Meta_Lead_Field_Mapping__c,
 *               Meta_Lead_Stage_Mapping__c) plus the new dynamic notification recipient list
 *               (Meta_Notification_Recipient__c) and a view onto Meta_Lead_Sync_Failure__c with
 *               a reprocess action (delegates to the existing MetaLeadSyncFailureResend).
 *
 *               Every read/write here is org-specific data on custom objects, not deployed
 *               Custom Metadata — saving a mapping or a Page token in this org never travels
 *               with a package deploy and can never overwrite another org's rows.
 */
public with sharing class MetaLeadCaptureSetupController {

    // =====================================================================
    // Integration Setting (singleton)
    // =====================================================================

    @AuraEnabled(cacheable=true)
    public static Meta_Integration_Config__c getIntegrationSetting() {
        // Meta_User_Access_Token__c is deliberately excluded — that token is only ever read
        // server-side by MetaOAuthConnectService and never needs to reach the client.
        // Meta_Token_Expires_At__c is included so the UI can show "connected until <date>"
        // without exposing the token itself.
        List<Meta_Integration_Config__c> rows = [
            SELECT Id, Setting_Key__c, Verify_Token__c, App_Secret__c, Dataset_ID__c,
                   Failure_Notification_Email__c, Meta_App_Id__c, Meta_App_Login_Config_Id__c,
                   Meta_Token_Expires_At__c,
                   Lead_Event_Source__c, Graph_API_Version__c, Max_Conversion_Sync_Attempts__c
            FROM Meta_Integration_Config__c
            WHERE Setting_Key__c = 'Default'
            LIMIT 1
        ];
        return rows.isEmpty() ? new Meta_Integration_Config__c(Setting_Key__c = 'Default') : rows[0];
    }

    // Powers the "Connect to Meta" embedded Facebook Login button — see
    // MetaOAuthConnectService for why this is fully separate from the Named
    // Credential/System User token the lead-capture pipeline itself uses.
    @AuraEnabled
    public static MetaOAuthConnectService.ConnectResult connectToMeta(String code, String redirectUri) {
        return MetaOAuthConnectService.connect(code, redirectUri);
    }

    @AuraEnabled
    public static Meta_Integration_Config__c saveIntegrationSetting(Meta_Integration_Config__c setting) {
        // Custom Setting fields can't be marked External ID, so this is a manual
        // find-existing-row-then-upsert-by-Id instead of an external-ID upsert.
        setting.Setting_Key__c = 'Default';
        List<Meta_Integration_Config__c> existing = [
            SELECT Id FROM Meta_Integration_Config__c WHERE Setting_Key__c = 'Default' LIMIT 1
        ];
        if (!existing.isEmpty()) {
            setting.Id = existing[0].Id;
        }
        upsert setting;
        return setting;
    }

    // =====================================================================
    // Page Config
    // =====================================================================

    @AuraEnabled(cacheable=true)
    public static List<Meta_Page_Setting__c> getPageConfigs() {
        return [
            SELECT Id, Page_Id__c, Page_Name__c, Page_Access_Token__c, Active__c
            FROM Meta_Page_Setting__c
            ORDER BY Page_Name__c NULLS LAST, Page_Id__c
        ];
    }

    @AuraEnabled
    public static Meta_Page_Setting__c savePageConfig(Meta_Page_Setting__c pageConfig) {
        // List Custom Settings require Name as the unique key — derive it from Page_Id__c so
        // callers (the setup page) don't need to supply one.
        if (String.isBlank(pageConfig.Name) && String.isNotBlank(pageConfig.Page_Id__c)) {
            pageConfig.Name = pageConfig.Page_Id__c;
        }
        upsert pageConfig;
        return pageConfig;
    }

    @AuraEnabled
    public static void deletePageConfig(Id recordId) {
        delete new Meta_Page_Setting__c(Id = recordId);
    }

    @AuraEnabled
    public static MetaPageSyncService.SyncResult syncPagesFromMeta() {
        return MetaPageSyncService.syncPages();
    }

    // =====================================================================
    // Lead Field Mapping
    // =====================================================================

    @AuraEnabled(cacheable=true)
    public static List<Meta_Field_Map__c> getFieldMappings() {
        return [
            SELECT Id, Form_Id__c, Form_Name__c, Meta_Field_Key__c, Meta_Field_Label__c,
                   Salesforce_Field_API_Name__c, Active__c
            FROM Meta_Field_Map__c
            ORDER BY Form_Id__c NULLS LAST, Meta_Field_Key__c
        ];
    }

    @AuraEnabled
    public static Meta_Field_Map__c saveFieldMapping(Meta_Field_Map__c mapping) {
        // List Custom Settings require Name as the unique key. A blank Form_Id__c is the
        // global fallback tier (Name = the key alone, matching the original global-only
        // behavior); a populated Form_Id__c scopes the row to one form, so it needs the form
        // id folded into the key too — otherwise a per-form row and the global row for the
        // same Meta_Field_Key__c would collide on Name.
        if (String.isBlank(mapping.Name) && String.isNotBlank(mapping.Meta_Field_Key__c)) {
            String key = String.isNotBlank(mapping.Form_Id__c)
                ? mapping.Form_Id__c + '_' + mapping.Meta_Field_Key__c
                : mapping.Meta_Field_Key__c;
            mapping.Name = key.length() > 80 ? key.substring(0, 80) : key;
        }
        upsert mapping;
        return mapping;
    }

    @AuraEnabled
    public static void deleteFieldMapping(Id recordId) {
        delete new Meta_Field_Map__c(Id = recordId);
    }

    @AuraEnabled
    public static MetaFormSyncService.SyncResult syncFormsFromMeta() {
        return MetaFormSyncService.syncForms();
    }

    // Live Graph API reads for the "New Lead Capture Mapping" picker — deliberately not
    // cacheable, since the picker should always show the form's current questions in Meta,
    // not a stale Lightning Data Service cache from an earlier visit.
    @AuraEnabled
    public static List<MetaFormSyncService.FormOption> getAvailableForms() {
        return MetaFormSyncService.listAllForms();
    }

    @AuraEnabled
    public static List<MetaFormSyncService.QuestionOption> getFormQuestions(String formId) {
        return MetaFormSyncService.listFormQuestions(formId);
    }

    @AuraEnabled(cacheable=true)
    public static List<PicklistOption> getLeadFieldOptions() {
        List<PicklistOption> options = new List<PicklistOption>();
        Map<String, Schema.SObjectField> fieldMap = Schema.SObjectType.Lead.fields.getMap();
        List<String> apiNames = new List<String>(fieldMap.keySet());
        apiNames.sort();
        for (String apiName : apiNames) {
            Schema.DescribeFieldResult dfr = fieldMap.get(apiName).getDescribe();
            if (dfr.isUpdateable()) {
                options.add(new PicklistOption(dfr.getLabel(), dfr.getName()));
            }
        }
        return options;
    }

    // =====================================================================
    // Lead Stage Mapping
    // =====================================================================

    @AuraEnabled(cacheable=true)
    public static List<Meta_Lead_Stage_Mapping__c> getStageMappings() {
        return [
            SELECT Id, Salesforce_Status__c, Meta_Event_Name__c, Active__c
            FROM Meta_Lead_Stage_Mapping__c
            ORDER BY Salesforce_Status__c
        ];
    }

    @AuraEnabled
    public static Meta_Lead_Stage_Mapping__c saveStageMapping(Meta_Lead_Stage_Mapping__c mapping) {
        upsert mapping;
        return mapping;
    }

    @AuraEnabled
    public static void deleteStageMapping(Id recordId) {
        delete new Meta_Lead_Stage_Mapping__c(Id = recordId);
    }

    @AuraEnabled(cacheable=true)
    public static List<PicklistOption> getLeadStatusOptions() {
        List<PicklistOption> options = new List<PicklistOption>();
        for (Schema.PicklistEntry entry : Lead.Status.getDescribe().getPicklistValues()) {
            if (entry.isActive()) {
                options.add(new PicklistOption(entry.getLabel(), entry.getValue()));
            }
        }
        return options;
    }

    // =====================================================================
    // Notification Recipients (dynamic Bell / Email / Both)
    // =====================================================================

    @AuraEnabled(cacheable=true)
    public static List<NotificationRecipientRow> getNotificationRecipients() {
        List<NotificationRecipientRow> rows = new List<NotificationRecipientRow>();
        for (Meta_Notify_Recipient__c r : Meta_Notify_Recipient__c.getAll().values()) {
            rows.add(new NotificationRecipientRow(r));
        }
        return rows;
    }

    @AuraEnabled
    public static void saveNotificationRecipient(Id recordId, Id userId, String channel, Boolean active) {
        // User_Name__c/User_Email__c are captured flat here (internal admin context — a plain
        // SOQL SELECT on User is fine) since Custom Settings can't hold a Lookup relationship.
        User u = [SELECT Name, Email FROM User WHERE Id = :userId LIMIT 1];
        upsert new Meta_Notify_Recipient__c(
            Id = recordId,
            Name = userId,
            User_Id__c = userId,
            User_Name__c = u.Name,
            User_Email__c = u.Email,
            Channel__c = channel,
            Active__c = active
        );
    }

    @AuraEnabled
    public static void deleteNotificationRecipient(Id recordId) {
        delete new Meta_Notify_Recipient__c(Id = recordId);
    }

    @AuraEnabled(cacheable=true)
    public static List<UserOption> searchUsers(String searchTerm) {
        String likeTerm = '%' + String.escapeSingleQuotes(String.isBlank(searchTerm) ? '' : searchTerm) + '%';
        List<UserOption> options = new List<UserOption>();
        for (User u : [
            SELECT Id, Name, Email
            FROM User
            WHERE IsActive = true AND (Name LIKE :likeTerm OR Email LIKE :likeTerm)
            ORDER BY Name
            LIMIT 25
        ]) {
            options.add(new UserOption(u));
        }
        return options;
    }

    // =====================================================================
    // Sync Failures (dead-letter queue + reprocess)
    // =====================================================================

    @AuraEnabled(cacheable=true)
    public static List<Meta_Lead_Sync_Failure__c> getSyncFailures() {
        return [
            SELECT Id, Name, Leadgen_Id__c, Page_Id__c, Failure_Reason__c, Status__c,
                   Attempts__c, Last_Attempt__c, Resolved_Lead__c
            FROM Meta_Lead_Sync_Failure__c
            WHERE Status__c != 'Resolved'
            ORDER BY Last_Attempt__c DESC
            LIMIT 200
        ];
    }

    @AuraEnabled
    public static List<ResendOutcome> resendFailures(List<Id> failureIds) {
        List<ResendOutcome> outcomes = new List<ResendOutcome>();
        for (MetaLeadSyncFailureResend.ResendResult r : MetaLeadSyncFailureResend.resend(failureIds)) {
            outcomes.add(new ResendOutcome(r));
        }
        return outcomes;
    }

    // =====================================================================
    // Wrapper types
    // =====================================================================

    public class PicklistOption {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
        public PicklistOption(String label, String value) {
            this.label = label;
            this.value = value;
        }
    }

    public class UserOption {
        @AuraEnabled public Id userId;
        @AuraEnabled public String name;
        @AuraEnabled public String email;
        public UserOption(User u) {
            this.userId = u.Id;
            this.name = u.Name;
            this.email = u.Email;
        }
    }

    public class NotificationRecipientRow {
        @AuraEnabled public Id id;
        @AuraEnabled public Id userId;
        @AuraEnabled public String userName;
        @AuraEnabled public String userEmail;
        @AuraEnabled public String channel;
        @AuraEnabled public Boolean active;
        public NotificationRecipientRow(Meta_Notify_Recipient__c r) {
            this.id = r.Id;
            this.userId = r.User_Id__c;
            this.userName = r.User_Name__c;
            this.userEmail = r.User_Email__c;
            this.channel = r.Channel__c;
            this.active = r.Active__c;
        }
    }

    public class ResendOutcome {
        @AuraEnabled public Id failureId;
        @AuraEnabled public Boolean success;
        @AuraEnabled public String message;
        public ResendOutcome(MetaLeadSyncFailureResend.ResendResult r) {
            this.failureId = r.failureId;
            this.success = r.success;
            this.message = r.message;
        }
    }
}