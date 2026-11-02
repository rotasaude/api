# Vínculo de um usuário à sala de vacina com o papel vaccinator ou room_lead
# (ADR 0047, Desvio 6). O papel vale com este vínculo ativo, a Membership
# health_professional e o ProfessionalLink com CBO de vacinador na unidade
# (Vaccination::Access). Nunca é apagado nem muda: só é revogado, uma vez
# (trigger).
class VaccineRoomStaff < ApplicationRecord
  self.table_name = "vaccine_room_staff"

  belongs_to :vaccine_room, inverse_of: :staff
  belongs_to :user
  belongs_to :granted_by_user, class_name: "User"
  belongs_to :revoked_by_user, class_name: "User", optional: true

  scope :active, -> { where(revoked_at: nil) }
end
