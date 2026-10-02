# Preferências de contato do cidadão (ADR 0024 §3.3; F-12.5): opt-in do SMS
# (explícito, desligado por padrão), silêncio dos avisos e, desde api#39, o
# opt-out dos lembretes de horário (ligados por padrão). Só as chaves
# presentes; valores booleanos. Sem linha = os três desligados (lembrete de horário ligado), então nada é
# gravado nem publicado quando nada muda. Evento só quando algo muda, só com o
# id e os booleanos. Reason: :invalid_preferences.
module Citizens
  class UpdateContactPreferences
    FIELDS = %w[sms_opt_in notices_muted appointment_reminders_muted].freeze

    def self.call(citizen:, changes:)
      changes = changes.to_h.stringify_keys.slice(*FIELDS)
      if changes.empty? || changes.values.any? { |value| ![ true, false ].include?(value) }
        return Result.fail(:invalid_preferences)
      end

      apply(citizen, changes)
    rescue ActiveRecord::RecordNotUnique
      # Duas requisições criaram a primeira linha ao mesmo tempo: a outra venceu.
      apply(citizen, changes)
    end

    def self.apply(citizen, changes)
      ApplicationRecord.transaction do
        preference = CitizenContactPreference.lock.find_by(citizen_id: citizen.id) ||
                     CitizenContactPreference.new(citizen_id: citizen.id)
        preference.assign_attributes(changes)
        preference.sms_opt_in_changed_at = Time.current if preference.sms_opt_in_changed?
        if (preference.changed & FIELDS).any?
          preference.save!
          DomainEvents.publish("citizen.contact_preferences_changed", citizen_id: citizen.id,
                                                                     sms_opt_in: preference.sms_opt_in,
                                                                     notices_muted: preference.notices_muted,
                                                                     appointment_reminders_muted:
                                                                       preference.appointment_reminders_muted)
        end
        Result.ok(preference: preference)
      end
    end
    private_class_method :apply
  end
end
