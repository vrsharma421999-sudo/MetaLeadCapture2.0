import { LightningElement } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

import getIntegrationSetting from '@salesforce/apex/MetaLeadCaptureSetupController.getIntegrationSetting';
import saveIntegrationSetting from '@salesforce/apex/MetaLeadCaptureSetupController.saveIntegrationSetting';
import connectToMeta from '@salesforce/apex/MetaLeadCaptureSetupController.connectToMeta';

import getPageConfigs from '@salesforce/apex/MetaLeadCaptureSetupController.getPageConfigs';
import savePageConfig from '@salesforce/apex/MetaLeadCaptureSetupController.savePageConfig';
import deletePageConfig from '@salesforce/apex/MetaLeadCaptureSetupController.deletePageConfig';
import syncPagesFromMeta from '@salesforce/apex/MetaLeadCaptureSetupController.syncPagesFromMeta';

import getFieldMappings from '@salesforce/apex/MetaLeadCaptureSetupController.getFieldMappings';
import saveFieldMapping from '@salesforce/apex/MetaLeadCaptureSetupController.saveFieldMapping';
import deleteFieldMapping from '@salesforce/apex/MetaLeadCaptureSetupController.deleteFieldMapping';
import getLeadFieldOptions from '@salesforce/apex/MetaLeadCaptureSetupController.getLeadFieldOptions';
import getAvailableForms from '@salesforce/apex/MetaLeadCaptureSetupController.getAvailableForms';
import getFormQuestions from '@salesforce/apex/MetaLeadCaptureSetupController.getFormQuestions';

import getStageMappings from '@salesforce/apex/MetaLeadCaptureSetupController.getStageMappings';
import saveStageMapping from '@salesforce/apex/MetaLeadCaptureSetupController.saveStageMapping';
import deleteStageMapping from '@salesforce/apex/MetaLeadCaptureSetupController.deleteStageMapping';
import getLeadStatusOptions from '@salesforce/apex/MetaLeadCaptureSetupController.getLeadStatusOptions';

import getNotificationRecipients from '@salesforce/apex/MetaLeadCaptureSetupController.getNotificationRecipients';
import saveNotificationRecipient from '@salesforce/apex/MetaLeadCaptureSetupController.saveNotificationRecipient';
import deleteNotificationRecipient from '@salesforce/apex/MetaLeadCaptureSetupController.deleteNotificationRecipient';
import searchUsers from '@salesforce/apex/MetaLeadCaptureSetupController.searchUsers';

import getSyncFailures from '@salesforce/apex/MetaLeadCaptureSetupController.getSyncFailures';
import resendFailures from '@salesforce/apex/MetaLeadCaptureSetupController.resendFailures';

const CHANNEL_OPTIONS = [
    { label: 'Bell (in-app)', value: 'Bell' },
    { label: 'Email', value: 'Email' },
    { label: 'Both', value: 'Both' }
];

export default class MetaLeadCaptureSetup extends LightningElement {
    isLoading = true;

    // ---- Integration Setting -------------------------------------------
    integrationSetting = {};
    isConnectingToMeta = false;

    // ---- Page Config ------------------------------------------------------
    pageConfigs = [];
    pageDraftValues = [];
    isSyncingPages = false;
    newPage = { pageId: '', pageName: '', active: true };
    pageColumns = [
        { label: 'Page Id', fieldName: 'Page_Id__c', editable: true },
        { label: 'Page Name', fieldName: 'Page_Name__c', editable: true },
        { label: 'Page Access Token', fieldName: 'Page_Access_Token__c', editable: true, type: 'text' },
        { label: 'Active', fieldName: 'Active__c', type: 'boolean', editable: true },
        { type: 'action', typeAttributes: { rowActions: [{ label: 'Delete', name: 'delete' }] } }
    ];

    // ---- Field Mapping ------------------------------------------------------
    fieldMappings = [];
    fieldDraftValues = [];
    leadFieldOptions = [];
    newFieldMapping = { metaFieldKey: '', sfField: '' };
    fieldColumns = [
        { label: 'Meta Field Key', fieldName: 'Meta_Field_Key__c', editable: true },
        { label: 'Salesforce Field API Name', fieldName: 'Salesforce_Field_API_Name__c', editable: true },
        { label: 'Active', fieldName: 'Active__c', type: 'boolean', editable: true },
        { type: 'action', typeAttributes: { rowActions: [{ label: 'Delete', name: 'delete' }] } }
    ];

    // ---- Lead Capture Mapping picker (per-form) ------------------------------
    showMappingModal = false;
    isLoadingForms = false;
    isLoadingQuestions = false;
    isSavingMapping = false;
    availableForms = [];
    selectedFormId = '';
    selectedFormLabel = '';
    mappingRows = [];

    // ---- Stage Mapping ------------------------------------------------------
    stageMappings = [];
    stageDraftValues = [];
    leadStatusOptions = [];
    newStageMapping = { status: '', eventName: '' };
    stageColumns = [
        { label: 'Lead Status', fieldName: 'Salesforce_Status__c', editable: true },
        { label: 'Meta Event Name', fieldName: 'Meta_Event_Name__c', editable: true },
        { label: 'Active', fieldName: 'Active__c', type: 'boolean', editable: true },
        { type: 'action', typeAttributes: { rowActions: [{ label: 'Delete', name: 'delete' }] } }
    ];

    // ---- Notification Recipients -------------------------------------------
    notifRecipients = [];
    notifSearchTerm = '';
    notifSearchResults = [];
    newNotif = { userId: '', channel: 'Bell', active: true };
    channelOptions = CHANNEL_OPTIONS;
    notifColumns = [
        { label: 'User', fieldName: 'userName' },
        { label: 'Email', fieldName: 'userEmail' },
        { label: 'Channel', fieldName: 'channel', editable: true },
        { label: 'Active', fieldName: 'active', type: 'boolean', editable: true },
        { type: 'action', typeAttributes: { rowActions: [{ label: 'Delete', name: 'delete' }] } }
    ];
    notifDraftValues = [];

    // ---- Sync Failures ------------------------------------------------------
    syncFailures = [];
    selectedFailureIds = [];
    syncColumns = [
        { label: 'Name', fieldName: 'Name' },
        { label: 'Leadgen Id', fieldName: 'Leadgen_Id__c' },
        { label: 'Page Id', fieldName: 'Page_Id__c' },
        { label: 'Status', fieldName: 'Status__c' },
        { label: 'Attempts', fieldName: 'Attempts__c', type: 'number' },
        { label: 'Last Attempt', fieldName: 'Last_Attempt__c', type: 'date', typeAttributes: { year: 'numeric', month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit' } },
        { label: 'Failure Reason', fieldName: 'Failure_Reason__c', wrapText: true }
    ];

    connectedCallback() {
        this._handleWindowMessage = this.handleWindowMessage.bind(this);
        window.addEventListener('message', this._handleWindowMessage);

        Promise.all([
            this.loadIntegrationSetting(),
            this.loadPageConfigs(),
            this.loadFieldMappings(),
            this.loadLeadFieldOptions(),
            this.loadStageMappings(),
            this.loadLeadStatusOptions(),
            this.loadNotificationRecipients(),
            this.loadSyncFailures()
        ]).finally(() => {
            this.isLoading = false;
        });
    }

    disconnectedCallback() {
        window.removeEventListener('message', this._handleWindowMessage);
    }

    // =========================================================================
    // Integration Setting
    // =========================================================================

    loadIntegrationSetting() {
        return getIntegrationSetting()
            .then((data) => { this.integrationSetting = { ...data }; })
            .catch((e) => this.notifyError('Failed to load integration settings', e));
    }

    handleIntegrationFieldChange(event) {
        const field = event.target.dataset.field;
        const value = event.target.type === 'checkbox' ? event.target.checked : event.target.value;
        this.integrationSetting = { ...this.integrationSetting, [field]: value };
    }

    handleSaveIntegrationSetting() {
        this.isLoading = true;
        saveIntegrationSetting(this.integrationSetting)
            .then(() => {
                this.notifySuccess('Integration settings saved');
                return this.loadIntegrationSetting();
            })
            .catch((e) => this.notifyError('Failed to save integration settings', e))
            .finally(() => { this.isLoading = false; });
    }

    get metaConnectIframeUrl() {
        return `/apex/MetaConnectFacebook?origin=${encodeURIComponent(window.location.origin)}`;
    }

    get metaConnectedUntilLabel() {
        const expiresAt = this.integrationSetting && this.integrationSetting.Meta_Token_Expires_At__c;
        return expiresAt ? new Date(expiresAt).toLocaleString() : '';
    }

    // Handles the postMessage the embedded MetaConnectFacebook Visualforce page sends once
    // Facebook Login completes — see MetaOAuthConnectService for why this whole flow is kept
    // separate from the pipeline's own Named Credential auth.
    handleWindowMessage(event) {
        if (!event.data || event.data.type !== 'META_OAUTH_CODE' || !event.data.code) {
            return;
        }
        this.isConnectingToMeta = true;
        connectToMeta({ code: event.data.code, redirectUri: event.data.redirectUri })
            .then((result) => {
                if (result.success) {
                    this.notifySuccess(
                        `${result.message} Found ${result.pagesFound} page(s) (${result.pagesAdded} new), `
                        + `${result.formsFound} form(s), ${result.newMappingsAdded} new question(s) to map.`
                    );
                } else {
                    this.notifyError(result.message || 'Connect to Meta failed', null);
                }
                return Promise.all([this.loadIntegrationSetting(), this.loadPageConfigs(), this.loadFieldMappings()]);
            })
            .catch((e) => this.notifyError('Connect to Meta failed', e))
            .finally(() => { this.isConnectingToMeta = false; });
    }

    // =========================================================================
    // Page Config
    // =========================================================================

    loadPageConfigs() {
        return getPageConfigs()
            .then((data) => { this.pageConfigs = data; })
            .catch((e) => this.notifyError('Failed to load Page configs', e));
    }

    handleNewPageChange(event) {
        const field = event.target.dataset.field;
        const value = event.target.type === 'checkbox' ? event.target.checked : event.target.value;
        this.newPage = { ...this.newPage, [field]: value };
    }

    handleAddPage() {
        if (!this.newPage.pageId) {
            this.notifyError('Page Id is required', null);
            return;
        }
        savePageConfig({
            pageConfig: {
                Page_Id__c: this.newPage.pageId,
                Page_Name__c: this.newPage.pageName,
                Active__c: this.newPage.active
            }
        })
            .then(() => {
                this.notifySuccess('Page config added');
                this.newPage = { pageId: '', pageName: '', active: true };
                return this.loadPageConfigs();
            })
            .catch((e) => this.notifyError('Failed to add Page config', e));
    }

    handlePageSave(event) {
        const draftValues = event.detail.draftValues;
        const recordInputs = draftValues.map((draft) => ({ pageConfig: { Id: draft.Id, ...draft } }));
        Promise.all(recordInputs.map((input) => savePageConfig(input)))
            .then(() => {
                this.notifySuccess('Page config(s) updated');
                this.pageDraftValues = [];
                return this.loadPageConfigs();
            })
            .catch((e) => this.notifyError('Failed to save Page config changes', e));
    }

    handlePageRowAction(event) {
        if (event.detail.action.name === 'delete') {
            deletePageConfig({ recordId: event.detail.row.Id })
                .then(() => {
                    this.notifySuccess('Page config deleted');
                    return this.loadPageConfigs();
                })
                .catch((e) => this.notifyError('Failed to delete Page config', e));
        }
    }

    handleSyncPages() {
        this.isSyncingPages = true;
        syncPagesFromMeta()
            .then((result) => {
                if (result.pagesSubscribeFailed > 0) {
                    this.notifyError(
                        `Found ${result.pagesFound} Page(s): added ${result.pagesAdded}, ${result.pagesSubscribeFailed} failed to subscribe — see Error_Log__c`,
                        null
                    );
                } else {
                    this.notifySuccess(`Found ${result.pagesFound} Page(s), added ${result.pagesAdded} new`);
                }
                return this.loadPageConfigs();
            })
            .catch((e) => this.notifyError('Page sync failed', e))
            .finally(() => { this.isSyncingPages = false; });
    }

    // =========================================================================
    // Lead Field Mapping
    // =========================================================================

    loadFieldMappings() {
        return getFieldMappings()
            .then((data) => { this.fieldMappings = data; })
            .catch((e) => this.notifyError('Failed to load field mappings', e));
    }

    loadLeadFieldOptions() {
        return getLeadFieldOptions()
            .then((data) => { this.leadFieldOptions = data; })
            .catch((e) => this.notifyError('Failed to load Lead field options', e));
    }

    // Rows in fieldMappings with no Form_Id__c are the global fallback tier — everything else
    // belongs to the picker-managed per-form section.
    get globalFieldMappings() {
        return this.fieldMappings.filter((m) => !m.Form_Id__c);
    }

    // One summary card per form that already has at least one mapping row (including rows
    // MetaFormSyncService's scheduled discovery seeded as inactive/unmapped), so the tab shows
    // "what's configured" without a live Graph API call.
    get configuredFormSummaries() {
        const byForm = {};
        for (const row of this.fieldMappings) {
            if (!row.Form_Id__c) {
                continue;
            }
            if (!byForm[row.Form_Id__c]) {
                byForm[row.Form_Id__c] = {
                    formId: row.Form_Id__c,
                    formName: row.Form_Name__c || row.Form_Id__c,
                    total: 0,
                    active: 0
                };
            }
            byForm[row.Form_Id__c].total += 1;
            if (row.Active__c) {
                byForm[row.Form_Id__c].active += 1;
            }
        }
        return Object.values(byForm).sort((a, b) => a.formName.localeCompare(b.formName));
    }

    get hasConfiguredForms() {
        return this.configuredFormSummaries.length > 0;
    }

    get hasNoAvailableForms() {
        return this.availableForms.length === 0;
    }

    get hasNoQuestions() {
        return this.mappingRows.length === 0;
    }

    get saveMappingDisabled() {
        return !this.selectedFormId || this.isLoadingQuestions || this.isSavingMapping;
    }

    handleNewFieldMappingChange(event) {
        const field = event.target.dataset.field;
        this.newFieldMapping = { ...this.newFieldMapping, [field]: event.target.value };
    }

    handleAddFieldMapping() {
        if (!this.newFieldMapping.metaFieldKey || !this.newFieldMapping.sfField) {
            this.notifyError('Meta field key and Salesforce field are both required', null);
            return;
        }
        saveFieldMapping({
            mapping: {
                Meta_Field_Key__c: this.newFieldMapping.metaFieldKey,
                Salesforce_Field_API_Name__c: this.newFieldMapping.sfField,
                Active__c: true
            }
        })
            .then(() => {
                this.notifySuccess('Global fallback mapping added');
                this.newFieldMapping = { metaFieldKey: '', sfField: '' };
                return this.loadFieldMappings();
            })
            .catch((e) => this.notifyError('Failed to add field mapping', e));
    }

    // =========================================================================
    // Lead Capture Mapping picker: New Lead Capture Mapping -> pick a form (live from
    // Meta) -> map each of that form's current questions to a Lead field, side by side.
    // =========================================================================

    handleOpenMappingModal() {
        this.showMappingModal = true;
        this.selectedFormId = '';
        this.selectedFormLabel = '';
        this.mappingRows = [];
        this.isLoadingForms = true;
        getAvailableForms()
            .then((data) => { this.availableForms = data; })
            .catch((e) => this.notifyError('Failed to load forms from Meta', e))
            .finally(() => { this.isLoadingForms = false; });
    }

    handleCloseMappingModal() {
        this.showMappingModal = false;
    }

    handleBackToFormList() {
        this.selectedFormId = '';
        this.selectedFormLabel = '';
        this.mappingRows = [];
    }

    handleSelectForm(event) {
        const formId = event.currentTarget.dataset.formId;
        const form = this.availableForms.find((f) => f.formId === formId);
        this.selectFormById(formId, form ? `${form.formName} (${form.pageName})` : formId);
    }

    handleEditFormMapping(event) {
        const formId = event.currentTarget.dataset.formId;
        const formName = event.currentTarget.dataset.formName;
        this.showMappingModal = true;
        // Edit jumps straight to the question list for this form — no need to make the admin
        // re-pick it from the live form list they already came from.
        if (!this.availableForms.some((f) => f.formId === formId)) {
            this.availableForms = [...this.availableForms, { formId, formName, pageId: '', pageName: '' }];
        }
        this.selectFormById(formId, formName);
    }

    selectFormById(formId, label) {
        this.selectedFormId = formId;
        this.selectedFormLabel = label;
        this.mappingRows = [];
        this.isLoadingQuestions = true;
        getFormQuestions({ formId })
            .then((questions) => {
                const existingForForm = this.fieldMappings.filter((m) => m.Form_Id__c === formId);
                this.mappingRows = questions.map((q) => {
                    const existing = existingForForm.find(
                        (m) => (m.Meta_Field_Key__c || '').toLowerCase() === (q.key || '').toLowerCase()
                    );
                    return {
                        key: q.key,
                        label: q.label,
                        sfField: existing && existing.Active__c ? existing.Salesforce_Field_API_Name__c : '',
                        existingId: existing ? existing.Id : null
                    };
                });
            })
            .catch((e) => this.notifyError('Failed to load form questions from Meta', e))
            .finally(() => { this.isLoadingQuestions = false; });
    }

    handleMappingRowFieldChange(event) {
        const key = event.currentTarget.dataset.key;
        const value = event.detail.value;
        this.mappingRows = this.mappingRows.map((r) => (r.key === key ? { ...r, sfField: value } : r));
    }

    handleSaveMapping() {
        const formMeta = this.availableForms.find((f) => f.formId === this.selectedFormId);
        const formName = formMeta ? formMeta.formName : this.selectedFormId;
        // A row with neither a chosen field nor a prior mapping has nothing to persist; a row
        // that HAD a mapping and was cleared still needs saving, so it gets deactivated rather
        // than silently left active with a stale target field.
        const toSave = this.mappingRows.filter((r) => r.sfField || r.existingId);
        if (toSave.length === 0) {
            this.notifyError('Pick at least one Salesforce field before saving', null);
            return;
        }
        this.isSavingMapping = true;
        Promise.all(
            toSave.map((r) =>
                saveFieldMapping({
                    mapping: {
                        Id: r.existingId,
                        Form_Id__c: this.selectedFormId,
                        Form_Name__c: formName,
                        Meta_Field_Key__c: r.key,
                        Meta_Field_Label__c: r.label,
                        Salesforce_Field_API_Name__c: r.sfField || null,
                        Active__c: !!r.sfField
                    }
                })
            )
        )
            .then(() => {
                this.notifySuccess(`Mapping saved for ${formName}`);
                this.showMappingModal = false;
                return this.loadFieldMappings();
            })
            .catch((e) => this.notifyError('Failed to save mapping', e))
            .finally(() => { this.isSavingMapping = false; });
    }

    handleFieldMappingSave(event) {
        const draftValues = event.detail.draftValues;
        Promise.all(draftValues.map((draft) => saveFieldMapping({ mapping: { Id: draft.Id, ...draft } })))
            .then(() => {
                this.notifySuccess('Field mapping(s) updated');
                this.fieldDraftValues = [];
                return this.loadFieldMappings();
            })
            .catch((e) => this.notifyError('Failed to save field mapping changes', e));
    }

    handleFieldMappingRowAction(event) {
        if (event.detail.action.name === 'delete') {
            deleteFieldMapping({ recordId: event.detail.row.Id })
                .then(() => {
                    this.notifySuccess('Field mapping deleted');
                    return this.loadFieldMappings();
                })
                .catch((e) => this.notifyError('Failed to delete field mapping', e));
        }
    }

    // =========================================================================
    // Lead Stage Mapping
    // =========================================================================

    loadStageMappings() {
        return getStageMappings()
            .then((data) => { this.stageMappings = data; })
            .catch((e) => this.notifyError('Failed to load stage mappings', e));
    }

    loadLeadStatusOptions() {
        return getLeadStatusOptions()
            .then((data) => { this.leadStatusOptions = data; })
            .catch((e) => this.notifyError('Failed to load Lead status options', e));
    }

    handleNewStageMappingChange(event) {
        const field = event.target.dataset.field;
        this.newStageMapping = { ...this.newStageMapping, [field]: event.target.value };
    }

    handleAddStageMapping() {
        if (!this.newStageMapping.status || !this.newStageMapping.eventName) {
            this.notifyError('Lead Status and Meta Event Name are both required', null);
            return;
        }
        saveStageMapping({
            mapping: {
                Salesforce_Status__c: this.newStageMapping.status,
                Meta_Event_Name__c: this.newStageMapping.eventName,
                Active__c: true
            }
        })
            .then(() => {
                this.notifySuccess('Stage mapping added');
                this.newStageMapping = { status: '', eventName: '' };
                return this.loadStageMappings();
            })
            .catch((e) => this.notifyError('Failed to add stage mapping', e));
    }

    handleStageMappingSave(event) {
        const draftValues = event.detail.draftValues;
        Promise.all(draftValues.map((draft) => saveStageMapping({ mapping: { Id: draft.Id, ...draft } })))
            .then(() => {
                this.notifySuccess('Stage mapping(s) updated');
                this.stageDraftValues = [];
                return this.loadStageMappings();
            })
            .catch((e) => this.notifyError('Failed to save stage mapping changes', e));
    }

    handleStageMappingRowAction(event) {
        if (event.detail.action.name === 'delete') {
            deleteStageMapping({ recordId: event.detail.row.Id })
                .then(() => {
                    this.notifySuccess('Stage mapping deleted');
                    return this.loadStageMappings();
                })
                .catch((e) => this.notifyError('Failed to delete stage mapping', e));
        }
    }

    // =========================================================================
    // Notification Recipients
    // =========================================================================

    loadNotificationRecipients() {
        return getNotificationRecipients()
            .then((data) => { this.notifRecipients = data; })
            .catch((e) => this.notifyError('Failed to load notification recipients', e));
    }

    handleNotifSearchTermChange(event) {
        this.notifSearchTerm = event.target.value;
    }

    handleSearchUsers() {
        searchUsers({ searchTerm: this.notifSearchTerm })
            .then((data) => {
                this.notifSearchResults = data.map((u) => ({ label: `${u.name} (${u.email})`, value: u.userId }));
                if (this.notifSearchResults.length === 0) {
                    this.notifyError('No active users matched that search', null);
                }
            })
            .catch((e) => this.notifyError('User search failed', e));
    }

    handleNewNotifUserChange(event) {
        this.newNotif = { ...this.newNotif, userId: event.target.value };
    }

    handleNewNotifChannelChange(event) {
        this.newNotif = { ...this.newNotif, channel: event.target.value };
    }

    handleNewNotifActiveChange(event) {
        this.newNotif = { ...this.newNotif, active: event.target.checked };
    }

    handleAddNotifRecipient() {
        if (!this.newNotif.userId) {
            this.notifyError('Search for and select a user first', null);
            return;
        }
        saveNotificationRecipient({
            recordId: null,
            userId: this.newNotif.userId,
            channel: this.newNotif.channel,
            active: this.newNotif.active
        })
            .then(() => {
                this.notifySuccess('Notification recipient added');
                this.newNotif = { userId: '', channel: 'Bell', active: true };
                this.notifSearchResults = [];
                this.notifSearchTerm = '';
                return this.loadNotificationRecipients();
            })
            .catch((e) => this.notifyError('Failed to add notification recipient', e));
    }

    handleNotifSave(event) {
        const draftValues = event.detail.draftValues;
        Promise.all(
            draftValues.map((draft) => {
                const existing = this.notifRecipients.find((r) => r.id === draft.id);
                return saveNotificationRecipient({
                    recordId: draft.id,
                    userId: existing.userId,
                    channel: draft.channel !== undefined ? draft.channel : existing.channel,
                    active: draft.active !== undefined ? draft.active : existing.active
                });
            })
        )
            .then(() => {
                this.notifySuccess('Notification recipient(s) updated');
                this.notifDraftValues = [];
                return this.loadNotificationRecipients();
            })
            .catch((e) => this.notifyError('Failed to save notification recipient changes', e));
    }

    handleNotifRowAction(event) {
        if (event.detail.action.name === 'delete') {
            deleteNotificationRecipient({ recordId: event.detail.row.id })
                .then(() => {
                    this.notifySuccess('Notification recipient removed');
                    return this.loadNotificationRecipients();
                })
                .catch((e) => this.notifyError('Failed to remove notification recipient', e));
        }
    }

    // =========================================================================
    // Sync Failures
    // =========================================================================

    loadSyncFailures() {
        return getSyncFailures()
            .then((data) => { this.syncFailures = data; })
            .catch((e) => this.notifyError('Failed to load sync failures', e));
    }

    handleSyncFailureSelection(event) {
        this.selectedFailureIds = event.detail.selectedRows.map((row) => row.Id);
    }

    get reprocessDisabled() {
        return this.selectedFailureIds.length === 0;
    }

    handleReprocessSelected() {
        this.isLoading = true;
        resendFailures({ failureIds: this.selectedFailureIds })
            .then((outcomes) => {
                const succeeded = outcomes.filter((o) => o.success).length;
                const failed = outcomes.length - succeeded;
                if (failed === 0) {
                    this.notifySuccess(`Reprocessed ${succeeded} lead(s) successfully`);
                } else {
                    this.notifyError(`${succeeded} succeeded, ${failed} still failing — see reasons on the list`, null);
                }
                this.selectedFailureIds = [];
                return this.loadSyncFailures();
            })
            .catch((e) => this.notifyError('Reprocess failed', e))
            .finally(() => { this.isLoading = false; });
    }

    // =========================================================================
    // Toasts
    // =========================================================================

    notifySuccess(message) {
        this.dispatchEvent(new ShowToastEvent({ title: 'Success', message, variant: 'success' }));
    }

    notifyError(title, error) {
        const detail = error && error.body && error.body.message ? error.body.message : (error && error.message) || '';
        this.dispatchEvent(new ShowToastEvent({ title, message: detail, variant: 'error', mode: 'sticky' }));
    }
}