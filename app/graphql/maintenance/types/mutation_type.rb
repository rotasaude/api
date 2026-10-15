module Maintenance
  module Types
    class MutationType < BaseObject
      description "Escritas da API de manutenção"

      field :invite_maintainer, mutation: Mutations::InviteMaintainer
      field :deactivate_maintainer, mutation: Mutations::DeactivateMaintainer
      field :create_maintenance_token, mutation: Mutations::CreateMaintenanceToken
      field :revoke_maintenance_token, mutation: Mutations::RevokeMaintenanceToken
      field :save_protocol_draft, mutation: Mutations::SaveProtocolDraft
      field :submit_protocol_for_review, mutation: Mutations::SubmitProtocolForReview
      field :publish_protocol, mutation: Mutations::PublishProtocol
      field :activate_protocol, mutation: Mutations::ActivateProtocol
      field :retire_protocol, mutation: Mutations::RetireProtocol
      field :revert_protocol_activation, mutation: Mutations::RevertProtocolActivation
      field :set_city_feature, mutation: Mutations::SetCityFeature
      field :import_medication_catalog, mutation: Mutations::ImportMedicationCatalog
      field :import_anvisa_lists, mutation: Mutations::ImportAnvisaLists
      field :set_city_pec_origin, mutation: Mutations::SetCityPecOrigin
      field :rotate_city_pec_hmac_key, mutation: Mutations::RotateCityPecHmacKey
      field :upsert_lab_exam_template, mutation: Mutations::UpsertLabExamTemplate
      field :upsert_lab_analyte_template, mutation: Mutations::UpsertLabAnalyteTemplate
    end
  end
end
