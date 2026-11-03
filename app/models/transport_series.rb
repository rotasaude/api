# Série recorrente (ADR 0048; hemodiálise, quimioterapia): dias ISO
# (1 = segunda … 7 = domingo), horários locais ("HH:MM"), embarque e, cifrados
# com a chave da cidade, prestador, endereço, acompanhante e o motivo da
# suspensão. O job materializa as viagens no horizonte. Nunca é apagada
# (trigger). Dado do paciente nunca sai em inspect, to_s, pretty_print nem
# as_json — só o id.
class TransportSeries < ApplicationRecord
  encrypts :provider_name, :address, :companion_name, :companion_document, :companion_reason, :suspend_reason

  belongs_to :patient
  belongs_to :transport_destination
  belongs_to :created_by_user, class_name: "User"
  has_many :transport_trips, inverse_of: :transport_series, dependent: :restrict_with_error
  has_many :transport_pending_items, inverse_of: :transport_series, dependent: :restrict_with_error

  # Horários da série são hora de relógio local ("HH:MM"), sem data: nada de
  # conversão de fuso (com ela o Rails os ancora em 2000-01-01, quando São
  # Paulo estava em horário de verão). A data e o fuso entram só na
  # materialização (Time.zone.parse("<dia> <HH:MM>")).
  self.skip_time_zone_conversion_for_attributes = %i[appointment_time departure_time return_time]

  # A regra única de série ativa (leitura <series>, origem "series" do
  # Transport::AddPassenger e o job): `suspended` se suspensa a partir de hoje
  # ou antes, `ended` se o fim já passou, senão `active`.
  def status_on(today)
    return "suspended" if suspended_from && suspended_from <= today
    return "ended" if ends_on && ends_on < today

    "active"
  end

  def active_on?(today) = status_on(today) == "active"

  # A série vale no dia `date`? Dia ISO da semana, dentro de [starts_on,
  # ends_on] e antes da suspensão.
  def runs_on?(date)
    weekdays.include?(date.cwday) && starts_on <= date && (ends_on.nil? || date <= ends_on) &&
      (suspended_from.nil? || date < suspended_from)
  end

  # "HH:MM" de uma coluna de hora.
  def clock(attribute) = self[attribute]&.strftime("%H:%M")

  def inspect = "#<TransportSeries id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
