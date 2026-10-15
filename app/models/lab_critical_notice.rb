# Aviso de valor crítico (ADR 0037; RDC 978): quem foi avisado (cifrado),
# função, canal e quando; só acréscimo.
class LabCriticalNotice < ApplicationRecord
  CHANNELS = %w[telefone presencial sistema].freeze

  encrypts :notified_person

  belongs_to :lab_result
  belongs_to :recorded_by_user, class_name: "User"

  def inspect = "#<LabCriticalNotice id=#{id} channel=#{channel}>"
end
