# Prontuário do CAPS na linha do tempo da equipe lotada (ADR 0049; contrato
# §10, P18): kind `psychosocial`, FORA de Timeline::KINDS (Query::CAPS_ONLY_KINDS),
# servido só por GET /psychosocial/enrollments/:id/timeline e sempre recortado
# pelo CAPS da matrícula (`health_unit_id`; sem ele, nada). Quatro origens do
# paciente naquele CAPS, numa só ordem total (Window, por tabela):
# - ação não cancelada em que ele é participante: nome SIGTAP da competência
#   do mês da ação, em `performed_at`, com o profissional e o CBO da ação;
# - versão do PTS: "PTS versão N", em `created_at`, com quem gravou;
# - permanência noturna: "Acolhimento noturno", em `started_at`;
# - documento do 19 emitido pela ação: o tipo, em `issued_at`.
# Nunca a evolução (`notes`), o CID, a substância nem o texto do PTS: o
# detalhe abre as telas do CAPS, com a trilha delas. `summary`, `citizen` e
# `document` nulos (não há visão do cidadão). A trilha é do controlador.
module Timeline
  module Sources
    module PsychosocialSource
      KIND = "psychosocial".freeze
      DOCUMENT_TITLES = Labels::DOCUMENT_KINDS.merge("controlled_notification_record" => "Registro da Notificação de Receita").freeze

      module_function

      def entries(person:, before:, limit:, from:, to:, health_unit_id: nil)
        return [] unless person.patient_id && health_unit_id

        unit = ::HealthUnit.find_by(id: health_unit_id, kind: "caps")
        return [] unless unit

        window = { before: before, from: from, to: to }
        rows = actions(person.patient_id, unit, window, limit) + care_plans(person.patient_id, unit, window, limit) +
               night_stays(person.patient_id, unit, window, limit) + documents(person.patient_id, unit, window, limit)
        rows.sort_by(&:sort_key).first(limit)
      end

      def actions(patient_id, unit, window, limit)
        scope = ::PsychosocialAction.active.where(health_unit_id: unit.id)
                                    .where(id: ::PsychosocialActionParticipant.where(patient_id: patient_id).select(:psychosocial_action_id))
                                    .includes(professional_user: :professional)
        labels = {}
        page(scope, "psychosocial_actions", "performed_at", window, limit).map do |action|
          competence = action.month.strftime("%Y%m")
          title = labels[[ action.sigtap_code, competence ]] ||= Billing::Labels.procedure(action.sigtap_code, competence)
          entry(action, at: action.performed_at, unit: unit, title: title, status: "recorded", type: "psychosocial_action",
                        professional: { name: Labels.professional_name(action.professional_user), cbo_code: action.cbo_code })
        end
      end

      def care_plans(patient_id, unit, window, limit)
        scope = ::PsychosocialCarePlan.joins(:psychosocial_enrollment)
                                      .where(psychosocial_enrollments: { patient_id: patient_id, health_unit_id: unit.id })
                                      .includes(created_by_user: :professional)
        page(scope, "psychosocial_care_plans", "created_at", window, limit).map do |plan|
          entry(plan, at: plan.created_at, unit: unit, title: "PTS versão #{plan.version}", status: "recorded", type: "psychosocial_care_plan",
                      professional: { name: Labels.professional_name(plan.created_by_user), cbo_code: nil })
        end
      end

      def night_stays(patient_id, unit, window, limit)
        scope = ::PsychosocialNightStay.where(patient_id: patient_id, health_unit_id: unit.id).includes(started_by_user: :professional)
        page(scope, "psychosocial_night_stays", "started_at", window, limit).map do |stay|
          entry(stay, at: stay.started_at, unit: unit, title: "Acolhimento noturno", status: stay.open? ? "open" : "closed",
                      type: "psychosocial_night_stay", professional: { name: Labels.professional_name(stay.started_by_user), cbo_code: nil })
        end
      end

      def documents(patient_id, unit, window, limit)
        scope = ::ClinicalDocument.where(patient_id: patient_id)
                                  .where(psychosocial_action_id: ::PsychosocialAction.where(health_unit_id: unit.id).select(:id))
                                  .includes(author_user: :professional)
        page(scope, "clinical_documents", "issued_at", window, limit).map do |document|
          entry(document, at: document.issued_at, unit: unit, title: DOCUMENT_TITLES.fetch(document.kind, document.kind),
                          status: document.status, type: "clinical_document",
                          professional: { name: Labels.professional_name(document.author_user), cbo_code: document.cbo_code })
        end
      end

      def page(scope, table, column, window, limit)
        Window.apply(scope, kind: KIND, column: "#{table}.#{column}", id_column: "#{table}.id", **window).limit(limit).to_a
      end

      def entry(record, at:, unit:, title:, status:, type:, professional:)
        Entry.new(kind: KIND, source_id: record.id, occurred_at: at, unit: { id: unit.id, name: unit.name }, professional: professional,
                  title: title, summary: nil, status: status, detail_ref: { type: type, id: record.id }, citizen: nil, document: nil)
      end
      private_class_method :actions, :care_plans, :night_stays, :documents, :page, :entry
    end
  end
end
