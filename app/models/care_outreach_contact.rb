# app/models/care_outreach_contact.rb
# Tentativa de contato da busca ativa (ADR 0040). Só acréscimo; nota cifrada.
class CareOutreachContact < ApplicationRecord
  encrypts :note

  belongs_to :enrollment, class_name: "CareLineEnrollment", inverse_of: :contacts
  belongs_to :recorded_by_user, class_name: "User"
end
