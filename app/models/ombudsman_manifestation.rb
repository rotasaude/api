# Manifestação da ouvidoria (ADR 0051): reclamação, denúncia, elogio, sugestão
# ou solicitação, com protocolo AAAA-NNNNNN (ombudsman_protocol_seq, ano local
# do recebimento). Guarda o estado e o que muda (classificação, ciclo, prazo);
# o texto ao longo do tempo vai a OmbudsmanEvent. Protocolo, texto, canal,
# modo, recebimento, criador e número do OuvidorSUS nunca mudam; citizen_id só
# vai a nulo (exclusão LGPD), com os manifestant_* (trigger). Nome, contato,
# CPF, telefone (o do cidadão excluído, §16 Q57), texto e motivo da
# prorrogação cifrados. Nunca sai em inspect, to_s, pretty_print nem as_json —
# só o id e o estado.
class OmbudsmanManifestation < ApplicationRecord
  encrypts :manifestant_name
  encrypts :manifestant_contact
  encrypts :manifestant_cpf
  encrypts :manifestant_phone
  encrypts :body
  encrypts :extension_reason

  belongs_to :citizen, optional: true
  belongs_to :subject, class_name: "OmbudsmanSubject", optional: true
  belongs_to :referred_health_unit, class_name: "HealthUnit", optional: true
  belongs_to :referred_professional, class_name: "Professional", optional: true
  belongs_to :duplicate_of, class_name: "OmbudsmanManifestation", optional: true
  belongs_to :created_by_user, class_name: "User", optional: true
  has_many :events, -> { order(:created_at, :id) }, class_name: "OmbudsmanEvent", inverse_of: :ombudsman_manifestation,
                                                    dependent: :restrict_with_error
  has_many :forwardings, -> { order(:created_at, :id) }, class_name: "OmbudsmanForwarding", inverse_of: :ombudsman_manifestation,
                                                         dependent: :restrict_with_error
  has_many :attachments, -> { order(:created_at, :id) }, class_name: "OmbudsmanAttachment", inverse_of: :ombudsman_manifestation,
                                                         dependent: :restrict_with_error
  has_many :identity_accesses, class_name: "OmbudsmanIdentityAccess", inverse_of: :ombudsman_manifestation, dependent: :restrict_with_error
  has_many :reopen_requests, -> { order(:cycle) }, class_name: "OmbudsmanReopenRequest", inverse_of: :ombudsman_manifestation,
                                                   dependent: :restrict_with_error
  has_many :notices, class_name: "OmbudsmanNotice", inverse_of: :ombudsman_manifestation, dependent: :restrict_with_error
  has_one :satisfaction_response, class_name: "OmbudsmanSatisfactionResponse", inverse_of: :ombudsman_manifestation,
                                  dependent: :restrict_with_error

  def self.next_protocol(received_at)
    "#{received_at.in_time_zone.year}-#{format('%06d', connection.select_value("SELECT nextval('ombudsman_protocol_seq')"))}"
  end

  def open? = Ombudsman::Catalog::OPEN_STATES.include?(state)
  def final? = Ombudsman::Catalog::FINAL_STATES.include?(state)
  def anonymous? = identification_mode == "anonymous"
  def identity_protected? = %w[preserved anonymous].include?(identification_mode)

  def inspect = "#<OmbudsmanManifestation id=#{id} state=#{state}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id, "state" => state }
end
