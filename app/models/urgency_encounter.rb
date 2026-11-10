# Encontro da urgência (ADR 0050; plano, Desvio 8): 1:1 com o atendimento
# `walk_in` da UPA, nascido só por Urgency::Arrive. O estado da fila, da
# chamada e do fechamento continua no atendimento (13); aqui fica o que é
# clínico da urgência — as classificações (só acréscimo, a vigente aponta a
# cor) e o desfecho. O estado só anda para frente e, fechado, congela
# (trigger). Nunca sai em inspect, to_s, pretty_print nem as_json — só o id.
class UrgencyEncounter < ApplicationRecord
  belongs_to :attendance
  belongs_to :consultation, optional: true
  # R4: o provisório com que o encontro nasceu (só na chegada do não
  # identificado); nunca muda, nem na fusão (trigger).
  belongs_to :provisional_patient, class_name: "Patient", optional: true
  belongs_to :current_classification, class_name: "UrgencyClassification", optional: true
  has_many :classifications, -> { order(:position) }, class_name: "UrgencyClassification", inverse_of: :urgency_encounter,
                                                       dependent: :restrict_with_error
  has_many :bed_stays, -> { order(:started_at, :id) }, class_name: "UrgencyBedStay", inverse_of: :urgency_encounter,
                                                        dependent: :restrict_with_error
  has_many :prescriptions, -> { order(:version) }, class_name: "UrgencyPrescription", inverse_of: :urgency_encounter,
                                                   dependent: :restrict_with_error
  has_one :outcome, class_name: "UrgencyOutcome", inverse_of: :urgency_encounter, dependent: :restrict_with_error

  validates :state, inclusion: { in: Urgency::Catalog::STATES }

  def patient = attendance.patient
  def closed? = state == "closed"
  def color = current_classification&.color
  # A estadia aberta no leito (no máximo uma: índice parcial).
  def open_stay = bed_stays.find_by(ended_at: nil)
  # A prescrição vigente (no máximo uma: índice parcial).
  def active_prescription = prescriptions.find_by(status: "active")

  # Estouro (Desvio 9; §14 Q18): minutos inteiros desde a 1ª classificação
  # acima do tempo máximo GRAVADO na classificação vigente (trocar o protocolo
  # não muda quem já foi classificado; reclassificar para cima estoura na
  # hora). Só de quem espera o médico (`classified`).
  def overdue?(at: Time.current)
    return false unless state == "classified" && first_classified_at && current_classification

    ((at - first_classified_at) / 60).floor > current_classification.max_wait_minutes
  end

  def inspect = "#<UrgencyEncounter id=#{id} state=#{state}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
