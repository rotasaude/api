# Procedimento que o TSB/ASB pode registrar (ADR 0046; Desvio 8): lista da
# cidade, editável pelo admin. A migração insere a semente; o banco carregado
# do dump nasce sem ela (ensure_defaults!).
class DentalAuxiliaryProcedure < ApplicationRecord
  belongs_to :created_by_user, class_name: "User", optional: true

  validates :procedure_code, format: { with: /\A\d{10}\z/ }, uniqueness: true

  # A semente de DentalCare::Catalog que falta; nunca mexe na gravada.
  def self.ensure_defaults!(now: Time.current)
    rows = DentalCare::Catalog::AUXILIARY_DEFAULT_PROCEDURES.map { |code| { "procedure_code" => code, "created_at" => now } }
    insert_all(rows, unique_by: :procedure_code)
    true
  end
end
