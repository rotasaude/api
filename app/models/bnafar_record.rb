# Registro enviado à BNAFAR (módulo 27b; contrato §3; Q8, Q14, Q16, Q25): uma
# posição de (CNES, item, parte) ou uma saída (um movimento). O payload é
# cifrado com a chave da cidade (CityEncryption) e vira NULL depois de
# PAYLOAD_DAYS; os erros são só os códigos MSG. A situação só anda para a
# frente (rejected → pending só no reenvio, R11); `bnafar_code` gravado não
# muda; `deleted_at` uma vez, só em aceito (trigger). O payload não sai em
# inspect, to_s, pretty_print nem as_json.
class BnafarRecord < ApplicationRecord
  encrypts :payload

  belongs_to :bnafar_submission, inverse_of: :records
  belongs_to :bnafar_batch, optional: true, inverse_of: :records
  belongs_to :stock_location
  belongs_to :replaces_record, class_name: "BnafarRecord", optional: true
  belongs_to :stock_external_exit, optional: true
  belongs_to :deletion_batch, class_name: "BnafarBatch", optional: true
  has_many :movement_links, class_name: "BnafarMovementLink", inverse_of: :bnafar_record

  def inspect = "#<BnafarRecord id=#{id} subject=#{subject} status=#{status} bnafar_code=#{bnafar_code.inspect}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
