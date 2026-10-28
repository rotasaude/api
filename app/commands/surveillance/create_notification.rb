# O único caminho de nascimento de uma notificação compulsória (módulo 25,
# ADR 0043): da consulta, manual ou da rede de segurança. Desvios 4–8 e 13:
#   - duplicidade (Duplicates.blocking) sob lock consultivo paciente×doença,
#     com o índice único parcial idx_disease_notifications_one_open como
#     última palavra — num savepoint, porque quem chama pode ser um consumidor
#     de evento cuja transação de fora tem de seguir utilizável;
#   - due_at = instante da suspeita + prazo da doença (congelado em deadline,
#     como a versão da lista); suspected_on = o dia desse instante na cidade;
#   - notificador: quem grava (consulta/manual); a rede de segurança nasce sem;
#   - bairro congelado (PatientNeighborhood.for) e ficha pré-preenchida (FormPrefill).
# Ordem de travas (Desvio 13): consulta (se quem chama a trava) → paciente
# (FOR UPDATE, aqui; nada muda para quem já o trava) → lock consultivo
# paciente×doença → notificação. O paciente vem antes do consultivo porque as
# FKs do INSERT tomam FOR KEY SHARE no paciente: quem segura o paciente e
# espera o consultivo, contra quem segura o consultivo e espera o KEY SHARE,
# seria deadlock.
# Entradas conferidas ANTES de gravar: o texto de erro do Postgres (CHECK,
# índice único) carrega valores da linha. Paciente, doença, data de sintomas e
# ficha nunca em log, evento, erro ou Result.
module Surveillance
  module CreateNotification
    OPEN_INDEX = "idx_disease_notifications_one_open".freeze
    INITIAL_STATUSES = %w[possible notified].freeze

    module_function

    # suspected_at: o instante da suspeita (consulta → agora; rede de segurança →
    # finalized_at da consulta ou created_at do adendo; manual → suspected_on às
    # 00:00 no fuso da cidade). -> Result.ok(notification:) |
    # fail(:already_notified, details: { notification_id: }) |
    # fail(:invalid_symptoms_on) | fail(:invalid_residence).
    def call(patient:, disease:, origin:, unit:, suspected_at:, by: nil, symptoms_on: nil, consultation: nil, addendum: nil,
             status: nil, resident_elsewhere: false, residence_ibge: nil)
      raise ArgumentError, "unknown origin" unless Catalog::ORIGINS.include?(origin)

      safety_net = origin == "safety_net"
      # Desvio 6: consulta e manual sempre com quem grava; a rede de segurança
      # nasce possible, sem notificador.
      raise ArgumentError, "by required for #{origin}" if !safety_net && by.nil?
      raise ArgumentError, "safety_net starts possible" if safety_net && !status.nil? && status != "possible"

      status ||= safety_net ? "possible" : "notified"
      raise ArgumentError, "unknown initial status" unless INITIAL_STATUSES.include?(status)

      suspected_at = suspected_at.in_time_zone
      suspected_on = suspected_at.to_date
      return Result.fail(:invalid_symptoms_on) unless symptoms_on.nil? || (symptoms_on.is_a?(Date) && symptoms_on <= suspected_on)
      return Result.fail(:invalid_residence) unless valid_residence?(resident_elsewhere, residence_ibge)

      ApplicationRecord.transaction do
        patient = Patient.lock.find(patient.id)
        ApplicationRecord.connection.execute("SELECT pg_advisory_xact_lock(#{lock_key(patient.id, disease.code)})")
        blocking = Duplicates.blocking(patient_id: patient.id, disease: disease, today: Time.zone.today)
        next already_notified(blocking.id) if blocking

        notifier = safety_net ? nil : by
        notification = insert(patient: patient, disease_code: disease.code, disease_list_version: disease.list_version,
                              deadline: disease.deadline, origin: origin, status: status, suspected_on: suspected_on,
                              symptoms_on: symptoms_on, due_at: suspected_at + Catalog::DEADLINES.fetch(disease.deadline),
                              health_unit: unit, unit_cnes: unit.cnes, notifier_user: notifier, consultation: consultation,
                              addendum: addendum, form: FormPrefill.for(patient, resident_elsewhere: resident_elsewhere),
                              resident_elsewhere: resident_elsewhere,
                              residence_ibge: residence_ibge, neighborhood_id: PatientNeighborhood.for(patient))
        next already_notified(open_id(patient.id, disease.code)) if notification.nil?

        DiseaseNotificationEvent.create!(notification: notification, status: status, by_user: notifier)
        DomainEvents.publish("disease_notification.created",
                             notification_id: notification.id,
                             immediate: notification.deadline == "immediate")
        Result.ok(notification: notification)
      end
    end

    # Savepoint próprio: a violação do índice desfaz só a inserção (nil); outra
    # violação de unicidade sobe sem tocar a mensagem.
    def insert(**attrs)
      DiseaseNotification.transaction(requires_new: true) { DiseaseNotification.create!(attrs) }
    rescue ActiveRecord::RecordNotUnique => e
      raise unless e.message.include?(OPEN_INDEX)

      nil
    end

    def valid_residence?(resident_elsewhere, residence_ibge)
      case resident_elsewhere
      when true then residence_ibge.is_a?(String) && residence_ibge.match?(Catalog::IBGE)
      when false then residence_ibge.nil?
      else false
      end
    end

    def open_id(patient_id, disease_code)
      DiseaseNotification.open_notifications.where(patient_id: patient_id, disease_code: disease_code).pick(:id)
    end

    def already_notified(notification_id) = Result.fail(:already_notified, details: { notification_id: notification_id })

    # Hash no Ruby: nem o paciente nem a doença no texto do SQL (log).
    def lock_key(patient_id, disease_code) = Digest::SHA256.hexdigest("surveillance:#{patient_id}:#{disease_code}")[0, 15].to_i(16)
    private_class_method :insert, :valid_residence?, :open_id, :already_notified, :lock_key
  end
end
