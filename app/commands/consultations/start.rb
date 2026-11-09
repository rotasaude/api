# app/commands/consultations/start.rb
# Iniciar a consulta (ADR 0031; spec §4): interruptor utilizável; atendimento
# in_care chamado por quem inicia; CBO permitido para o tipo; par validado;
# paciente resolvido pelo CPF (Patients::Resolve). Uma por atendimento: o lock
# do atendimento serializa duas abas do mesmo profissional; o índice único é a
# última palavra. Ordem de travas: atendimento → CPF → par → paciente.
# Módulo 28 (ADR 0046; Desvios 1, 2, 10, 14): `kind` "general" (padrão) ou
# "dental" (interruptor dental_care, lido fora da transação); `baseline` (o
# registro inicial) só do dentista, sem tipo de atendimento; a odontológica
# grava `pregnant` pela inscrição ativa na linha de pré-natal.
# Módulo 32a (ADR 0050; contrato §7, §14 Q10; plano, Desvio 14): o tipo vem
# do encontro da urgência — `kind` omitido é `urgency` com encontro e
# `general` sem; `urgency` sem encontro, ou `general`/`dental` com, →
# invalid_request `kind`. A urgência pede urgency_care utilizável (lido fora
# da transação) e o médico (225*) na unidade; o paciente é o do atendimento
# (o provisório inclusive; nunca um fundido), sem Patients::Resolve e sem tipo
# de atendimento; o encontro recebe a consulta na mesma transação.
module Consultations
  class Start
    def self.call(attendance:, by:, kind: nil, baseline: false, city: Current.city)
      encounter = UrgencyEncounter.find_by(attendance_id: attendance.id)
      kind = (encounter ? "urgency" : "general") if kind.nil?
      return Result.fail(:invalid_request, details: { path: "kind" }) unless Consultation::KINDS.include?(kind)
      return Result.fail(:invalid_request, details: { path: "kind" }) if (kind == "urgency") != encounter.present?
      return Result.fail(:invalid_request, details: { path: "baseline" }) unless [ true, false ].include?(baseline)
      return Result.fail(:feature_disabled) unless ClinicalRecord::Gate.usable?(city)
      dental = kind == "dental"
      urgency = kind == "urgency"
      return Result.fail(:feature_disabled, details: { feature: DentalCare::Gate::KEY }) if dental && !DentalCare::Gate.usable?(city)
      return Result.fail(:feature_disabled, details: { feature: Urgency::Gate::KEY }) if urgency && !Urgency::Gate.usable?(city)
      return Result.fail(:baseline_requires_dentist) if baseline && !dental

      ApplicationRecord.transaction do
        attendance.lock!
        status, link = link(by, attendance, kind, baseline)
        next Result.fail(status) unless status == :ok
        next Result.fail(:not_in_care) unless attendance.status == "in_care"
        next Result.fail(:not_caller) unless attendance.called_by_user_id == by.id

        existing = Consultation.find_by(attendance_id: attendance.id)
        next Result.fail(:already_exists, details: { consultation_id: existing.id }) if existing

        if urgency
          # O lock! do atendimento (acima) serializa com a identificação, que
          # trava o atendimento antes de mover o paciente: aqui ele já é o vigente.
          patient = attendance.patient_id && Patient.find_by(id: attendance.patient_id)
          next Result.fail(:invalid_request, details: { path: "patient" }) if patient.nil? || patient.merged?
        else
          resolved = Patients::Resolve.call(attendance.citizen)
          next resolved if resolved.failure?

          patient = resolved.payload[:patient]
        end
        consultation = Consultation.create!(
          attendance: attendance, patient: patient, author_user: by, professional_link: link,
          cbo_code: link.cbo_code, status: "draft", kind: kind, baseline: baseline,
          care_type: baseline || urgency ? nil : CareType.suggest(attendance), pregnant: dental ? pregnant(patient) : nil,
          started_at: Time.current
        )
        encounter.lock!.update!(consultation: consultation) if urgency
        DomainEvents.publish("consultation.started", consultation_id: consultation.id, attendance_id: attendance.id)
        Result.ok(consultation: consultation)
      end
    end

    # O registro inicial pede um vínculo de dentista na unidade; quem só tem
    # vínculo de TSB/ASB recebe baseline_requires_dentist.
    def self.link(by, attendance, kind, baseline)
      status, link = Authorization.link_for(user: by, health_unit_id: attendance.health_unit_id, kind: kind)
      return [ status, link ] unless status == :ok && baseline && Cbos.role(link.cbo_code) != :dentist

      status, link = Authorization.link_for(user: by, health_unit_id: attendance.health_unit_id, kind: kind, role: :dentist)
      status == :ok ? [ status, link ] : [ :baseline_requires_dentist, nil ]
    end

    # Desvio 10: inscrição ativa numa linha de pré-natal → true; senão nulo
    # (a finalização exige a resposta no sexo feminino).
    def self.pregnant(patient)
      CareLineEnrollment.active_enrollments.joins(:care_line)
                        .where(patient_id: patient.id, care_lines: { template_key: DentalCare::Catalog::PREGNANCY_TEMPLATE })
                        .exists? || nil
    end
    private_class_method :link, :pregnant
  end
end
