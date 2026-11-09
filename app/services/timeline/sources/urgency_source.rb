# Atendimentos de urgência da UPA (ADR 0050; contrato §10 e §14 Q13, Q25): um
# por encontro do paciente da pessoa (attendances.patient_id: depois da
# identificação, o do real), na chegada (attendances.checked_in_at). Vazio sem
# paciente. A entrada representa a visita inteira: o atendimento walk_in
# (AttendanceSource) e a consulta de urgência (ConsultationSource) não saem.
#
# Profissional, em qualquer estado: título "Atendimento de urgência — <UPA>";
# resumo com a cor vigente, o 1º CID-10 avaliado na consulta finalizada, o
# desfecho e a orientação de retorno com o motivo; situação = estado do
# encontro; profissional = autor da consulta (ou nulo); detail_ref = a consulta
# de urgência finalizada (abre pelas regras de leitura da consulta do 19a), ou
# nulo sem ela.
#
# Página do PEC externo (`pec: true`; contrato §14 Q27): a forma do
# profissional, sem o motivo da orientação de retorno, sem o registro por
# engano e sem paciente provisório. O mesmo recorte de NON_CARE_OUTCOMES e do
# provisório vale para o cidadão.
#
# Cidadão (`citizen: true`): só encontros FECHADOS de paciente identificado,
# com desfecho da tabela W3 (Labels::CITIZEN_URGENCY_OUTCOMES) — o óbito e o
# registro por engano nunca aparecem. Título igual, resumo = o desfecho em
# texto simples, `return_guidance` = "Procure a sua UBS em até N dias" (sem o
# motivo); profissional, situação e documento nulos. Nunca CID, cor, queixa,
# critério, sinais, destino nem motivo. A visão do cidadão só é montada para o
# encontro elegível (nula nos demais, e Timeline::Json.citizen a pula): mesmo
# sem o recorte no SQL, nada vaza. A trilha é do controlador.
module Timeline
  module Sources
    module UrgencySource
      KIND = "urgency".freeze

      module_function

      def entries(person:, before:, limit:, from:, to:, citizen: false, pec: false)
        return [] unless person.patient_id

        scope = ::UrgencyEncounter.joins(:attendance).where(attendances: { patient_id: person.patient_id })
                                  .preload(:outcome, :current_classification, attendance: %i[health_unit patient],
                                                                              consultation: [ :problem_items, { author_user: :professional } ])
        scope = citizen_scope(scope) if citizen
        scope = pec_scope(scope) if pec
        # preload (não includes): o where em attendances levaria ao eager_load com limite e ORDER BY cru.
        rows = Window.apply(scope, kind: KIND, column: "attendances.checked_in_at", id_column: "urgency_encounters.id",
                                   before: before, from: from, to: to).limit(limit).to_a
        labels = {} # memo da chamada: um rótulo por (release, código)
        rows.map { |encounter| entry(encounter, labels, pec: pec) }
      end

      def citizen_scope(scope)
        scope.where(state: "closed").joins(:outcome).where(urgency_outcomes: { kind: Labels::CITIZEN_URGENCY_OUTCOMES.keys })
             .joins(attendance: :patient).where(patients: { unidentified: false })
      end

      # Sem desfecho (aberto) entra; o registro por engano, não.
      def pec_scope(scope)
        scope.joins(attendance: :patient).where(patients: { unidentified: false })
             .where("NOT EXISTS (SELECT 1 FROM urgency_outcomes o WHERE o.urgency_encounter_id = urgency_encounters.id " \
                    "AND o.kind IN (?))", ::Urgency::Catalog::NON_CARE_OUTCOMES)
      end

      # A mesma regra do citizen_scope, no objeto: fechado, desfecho da tabela W3, paciente identificado.
      def citizen_eligible?(encounter)
        outcome = encounter.outcome
        encounter.closed? && outcome && Labels::CITIZEN_URGENCY_OUTCOMES.key?(outcome.kind) && !encounter.attendance.patient.unidentified
      end

      def entry(encounter, labels, pec: false)
        unit = encounter.attendance.health_unit
        outcome = encounter.outcome
        consultation = encounter.consultation&.then { |c| c.status == "finalized" ? c : nil }
        title = "Atendimento de urgência — #{Labels.unit_name(unit)}"
        guidance = outcome&.return_days
        summary = [ Labels::URGENCY_COLORS[encounter.color], cid(consultation, labels), outcome && Labels::URGENCY_OUTCOMES[outcome.kind],
                    guidance && return_note(guidance, outcome, pec: pec) ].compact.join(" · ")
        citizen = nil
        if citizen_eligible?(encounter)
          citizen = { title: title, summary: Labels::CITIZEN_URGENCY_OUTCOMES[outcome.kind], status: nil, professional_name: nil }
          citizen[:return_guidance] = ::Urgency::ReturnGuidance.citizen(guidance) if guidance
        end
        Entry.new(kind: KIND, source_id: encounter.id, occurred_at: encounter.attendance.checked_in_at, unit: Labels.unit(unit),
                  professional: consultation && { name: Screenings::Json.staff_name(consultation.author_user), cbo_code: consultation.cbo_code },
                  title: title, summary: summary.presence, status: encounter.state,
                  detail_ref: consultation && { type: "consultation", id: consultation.id }, citizen: citizen, document: nil)
      end

      # A orientação de retorno com o motivo; na página do PEC externo, sem o
      # motivo (texto clínico livre: Q27 leva só data, unidade, cor, CID e desfecho).
      def return_note(days, outcome, pec:)
        note = ::Urgency::ReturnGuidance.note(days)
        pec ? note : "#{note}: #{outcome.return_reason}"
      end

      # O 1º CID-10 avaliado na consulta (sem os de adendo), "CÓDIGO nome" pela release gravada.
      def cid(consultation, labels)
        return nil unless consultation

        item = consultation.problem_items.select { |p| p.addendum_id.nil? && p.terminology == "cid10" }.min_by { |p| [ p.created_at, p.id ] }
        return nil unless item

        key = [ item.terminology_release_id, item.code ]
        label = labels.fetch(key) { labels[key] = ClinicalTerms.label("cid10", item.code, item.terminology_release_id) }
        "#{item.code} #{label}".strip
      end
      private_class_method :citizen_scope, :pec_scope, :citizen_eligible?, :entry, :return_note, :cid
    end
  end
end
