# Importação do saldo inicial pela planilha conferida pela própria cidade
# (módulo 27b; contrato §5; Q11, Q20). Nunca some; a situação anda uploaded →
# validated → applied | discarded e applied → reverted, sempre com version + 1
# (trigger). O arquivo é cifrado (CityEncryption), apagado ao aplicar ou
# descartar, e não sai em inspect, to_s, pretty_print nem as_json.
class OpeningImport < ApplicationRecord
  STATUSES = %w[uploaded validated applied discarded reverted].freeze

  encrypts :file_data

  belongs_to :uploaded_by_user, class_name: "User"
  belongs_to :applied_by_user, class_name: "User", optional: true
  has_many :rows, class_name: "OpeningImportRow", inverse_of: :opening_import

  def inspect = "#<OpeningImport id=#{id} status=#{status} version=#{version}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
