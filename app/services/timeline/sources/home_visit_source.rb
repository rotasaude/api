# Visita domiciliar na linha do tempo (módulo 24b, ADR 0052; contrato §12, Q18,
# Q22, Q23): uma entrada por visita do paciente da pessoa (home_visits.patient_id:
# o morador ou, na visita à família, o responsável — os outros moradores não a
# veem). Vazia sem paciente.
#
# Profissional: todos os desfechos e a retirada; título "Visita domiciliar"
# ("Visita ao imóvel" sem pessoa, que nunca chega a uma linha do tempo de
# paciente); resumo com o desfecho, os rótulos dos motivos e das medidas (sem
# valores); profissional = dono da folha, com o CBO da folha; unidade = a da
# equipe da folha; status recorded | withdrawn; detail_ref { type: "home_visit",
# id } (o dashboard não abre nesta entrega, Q18); occurred_at = hora real.
#
# Cidadão (`citizen: true`): só outcome 1 não retirada, sem unidade,
# profissional, resumo, status nem documento, título "Visita do agente de saúde"
# (Q22). occurred_at = meio-dia local de home_visit_days.day (a hora real não
# sai do servidor): a ordem, a janela (from/to) e o cursor usam o mesmo
# meio-dia no SQL (noon_sql, como o trecho do TFD do módulo 30), então o
# cursor da página e o occurred_at da entrada são o mesmo instante.
#
# Nunca a observação (note) nem o motivo da retirada. NÃO consulta o
# interruptor `home_visits`: a visita é registro retido (como a vacina e a
# viagem). A trilha é do controlador.
module Timeline
  module Sources
    module HomeVisitSource
      KIND = "home_visit".freeze
      TITLE = "Visita domiciliar".freeze
      PROPERTY_TITLE = "Visita ao imóvel".freeze
      CITIZEN_TITLE = "Visita do agente de saúde".freeze
      DONE = 1
      DOMAINS = ::HomeVisits::Json::DICTIONARIES.fetch("domains")
      OUTCOMES = DOMAINS.fetch("desfecho").freeze
      REASONS = DOMAINS.fetch("motivo_visita").transform_values { |row| row.fetch("label") }.freeze
      # Rótulo de cada medida (as chaves de HomeVisits::Catalog::MEASUREMENTS); a pressão e a glicemia, um rótulo para o par.
      MEASUREMENTS = { "weight_kg" => "peso", "height_cm" => "altura", "systolic" => "pressão arterial", "diastolic" => "pressão arterial",
                       "temperature_c" => "temperatura", "glucose_mg_dl" => "glicemia", "glucose_type" => "glicemia" }.freeze

      module_function

      def entries(person:, before:, limit:, from:, to:, citizen: false)
        return [] unless person.patient_id

        citizen ? citizen_entries(person.patient_id, before, limit, from, to) : professional_entries(person.patient_id, before, limit, from, to)
      end

      def professional_entries(patient_id, before, limit, from, to)
        scope = ::HomeVisit.where(patient_id: patient_id).includes(home_visit_day: [ :professional, { team: :health_unit } ])
        Window.apply(scope, kind: KIND, column: "home_visits.occurred_at", id_column: "home_visits.id", before: before, from: from, to: to)
              .limit(limit).map { |visit| professional_entry(visit) }
      end
      private_class_method :professional_entries

      def citizen_entries(patient_id, before, limit, from, to)
        scope = ::HomeVisit.valid.where(patient_id: patient_id, outcome: DONE).joins(:home_visit_day)
        Window.apply(scope, kind: KIND, column: noon_sql, id_column: "home_visits.id", before: before, from: from, to: to)
              .limit(limit).pluck("home_visits.id", "home_visit_days.day").map { |id, day| citizen_entry(id, day) }
      end
      private_class_method :citizen_entries

      def professional_entry(visit)
        sheet = visit.home_visit_day
        Entry.new(kind: KIND, source_id: visit.id, occurred_at: visit.occurred_at, unit: Labels.unit(sheet.team.health_unit),
                  professional: { name: sheet.professional.professional_name, cbo_code: sheet.cbo },
                  title: visit.patient_id ? TITLE : PROPERTY_TITLE, summary: summary(visit),
                  status: visit.withdrawn? ? "withdrawn" : "recorded", detail_ref: { type: "home_visit", id: visit.id },
                  citizen: nil, document: nil)
      end
      private_class_method :professional_entry

      # Só o id e o dia saem do banco: a forma do cidadão não tem mais nada.
      def citizen_entry(id, day)
        Entry.new(kind: KIND, source_id: id, occurred_at: Time.zone.parse("#{day.iso8601} 12:00"), unit: nil, professional: nil,
                  title: CITIZEN_TITLE, summary: nil, status: nil, detail_ref: nil,
                  citizen: { title: CITIZEN_TITLE, summary: nil, status: nil, professional_name: nil, unit: nil }, document: nil)
      end
      private_class_method :citizen_entry

      # "Visita realizada · Visita periódica, Gestante · peso, altura": desfecho, motivos e medidas (sem valores).
      def summary(visit)
        reasons = Array(visit.reasons).filter_map { |code| REASONS[code.to_i] }
        measures = visit.measurements.to_h.keys.filter_map { |key| MEASUREMENTS[key.to_s] }.uniq
        [ OUTCOMES[visit.outcome], reasons.join(", ").presence, measures.join(", ").presence ].compact.join(" · ").presence
      end
      private_class_method :summary

      # Meio-dia local do dia da folha, como timestamp UTC sem fuso (o tipo das
      # colunas datetime), para a ordem, a janela e o cursor no SQL.
      def noon_sql
        zone = ApplicationRecord.connection.quote(Time.zone.tzinfo.identifier)
        "(((home_visit_days.day + TIME '12:00') AT TIME ZONE #{zone}) AT TIME ZONE 'UTC')"
      end
      private_class_method :noon_sql
    end
  end
end
