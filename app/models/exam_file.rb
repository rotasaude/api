# Guia ou laudo (ADR 0036): bytes em Base64 cifrados com a chave da cidade
# (como Signature#signed_pdf). Nunca mudam; consumed_at quando ligado a um
# pedido ou resultado; o órfão de 24 h é apagado pelo job diário.
class ExamFile < ApplicationRecord
  encrypts :data

  belongs_to :uploaded_by_user, class_name: "User", optional: true
  belongs_to :exam_provider, optional: true

  def bytes = Base64.strict_decode64(data)
  def consumed? = consumed_at.present?
  def inspect = "#<ExamFile id=#{id} content_type=#{content_type} byte_size=#{byte_size} consumed=#{consumed?}>"
end
