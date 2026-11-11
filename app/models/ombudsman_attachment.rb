# Anexo da manifestação (ADR 0051; plano, Desvio 6; Q2): nasce órfão no upload
# (dono = a sessão do cidadão, uuid sem FK, ou o usuário) e é ligado uma vez
# (trigger); o órfão some em cascata com o ExamFile órfão do Exams::DailyJob.
# O nome é cifrado e nunca mostrado (as telas dizem "Anexo N"); nunca sai em
# inspect, to_s, pretty_print nem as_json.
class OmbudsmanAttachment < ApplicationRecord
  UPLOADERS = %w[citizen staff].freeze

  encrypts :filename

  belongs_to :ombudsman_manifestation, optional: true
  belongs_to :exam_file
  belongs_to :uploaded_by_user, class_name: "User", optional: true
  belongs_to :event, class_name: "OmbudsmanEvent", optional: true

  def inspect = "#<OmbudsmanAttachment id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
