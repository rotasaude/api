# Horário na forma única (contratos §4.4, §9, §10): agenda da unidade, fila e
# Minha agenda. `legacy` não tem fim, tipo, profissional nem turno. A
# justificativa do encaixe só vai para quem marca e para o municipal_admin
# (show_reason). `citizen` sem `name` (o cadastro não tem nome).
# Guarda as faixas por turno: uma agenda inteira calcula cada turno uma vez.
# Quem chama carrega includes(:citizen, :professional, shift: [:professional_link, :schedule_template]).
module Scheduling
  class AppointmentPresenter
    def initialize(show_reason:, catalog: AppointmentTypes.catalog, zone: Time.zone)
      @show_reason = show_reason
      @catalog = catalog
      @zone = zone
      @blocks = {}
    end

    def call(appointment)
      legacy = appointment.booking_kind == "legacy"
      professional = legacy ? nil : appointment.professional
      json = {
        id: appointment.id, status: appointment.status, booking_kind: appointment.booking_kind,
        scheduled_at: appointment.scheduled_at.iso8601, ends_at: legacy ? nil : appointment.ends_at&.iso8601,
        appointment_type_key: legacy ? nil : appointment.appointment_type_key,
        appointment_type_name: legacy ? nil : @catalog.name_for(appointment.appointment_type_key),
        professional: professional && { id: professional.id, name: professional.professional_name },
        shift_id: legacy ? nil : appointment.shift_id, fit_in: appointment.fit_in?,
        outside_template: outside_template?(appointment),
        shift_cancelled: appointment.shift&.cancelled_at.present? || false,
        citizen: { id: appointment.citizen_id, cpf_masked: appointment.citizen.cpf_masked }
      }
      json[:fit_in_reason] = appointment.fit_in_reason if @show_reason && appointment.fit_in?
      json
    end

    private

    # Vaga que não cabe mais numa faixa `bookable` do seu tipo no modelo atual
    # do turno (modelo trocado ou editado depois da marcação).
    def outside_template?(appointment)
      return false unless appointment.booking_kind == "slot" && appointment.shift

      blocks = (@blocks[appointment.shift_id] ||= Availability.blocks_for(
        Availability.shift_data(appointment.shift), types: @catalog.active, fallback: @catalog.fallback, zone: @zone
      ))
      blocks.none? do |b|
        b.kind == "bookable" && b.appointment_type_key == appointment.appointment_type_key &&
          b.starts_at <= appointment.scheduled_at && b.ends_at >= appointment.ends_at
      end
    end
  end
end
