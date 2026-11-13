require "rails_helper"

# Módulo 24b (ADR 0052; contrato §9.4; Ruling A5 da Task 6): o domains-v1.json
# do contracts é o espelho, em dado, do que o api decide. Este spec confere a
# cópia presa em config/field_sync/ contra a fonte do api:
#   - os domínios e as regras da visita e da atividade em
#     config/ledi/visit_activity_dictionaries.yml, servidos por
#     HomeVisits::Json.domains / CollectiveActivities::Json.domains e usados
#     pelas constantes de HomeVisits::Catalog, CollectiveActivities::Catalog e
#     CollectiveActivities::Rules (códigos, rótulos e ORDEM — Q39);
#   - a atribuição por CBO (Tabela 7: quem registra visita; só o ACS fora de
#     área) e o turno pelo relógio (HomeVisits::Rules.shift);
#   - sexo e justificativa sem CPF do 24a (TerritoryRegistry::Catalog);
#   - os códigos de erro: os HTTP que a FieldAuthentication responde estão em
#     errors.http, e todo código que as regras e os comandos de registro da
#     visita, da retirada e da atividade (Tasks 6–15) recusam está em errors.item.
RSpec.describe "FieldSync domains-v1.json × api (Ruling A5)" do
  let(:domains) { FieldSync::Schemas.domains }
  let(:hv) { domains.fetch("home_visit") }
  let(:ca) { domains.fetch("collective_activity") }
  let(:yaml) { YAML.load_file(Rails.root.join("config/ledi/visit_activity_dictionaries.yml")) }
  let(:hv_rules) { hv.fetch("rules") }
  let(:ca_rules) { ca.fetch("rules") }

  def pairs(rows) = rows.map { |row| [ row.fetch(:code), row.fetch(:label) ] }
  def contract_pairs(rows) = rows.map { |row| [ row.fetch("code"), row.fetch("label") ] }

  describe "visita domiciliar" do
    it "motivo_visita: grupos, rótulos dos grupos, códigos, rótulos e ordem" do
      api = HomeVisits::Json.domains.fetch(:motivo_visita).map { |row| [ row[:group], row[:group_label], row[:code], row[:label] ] }
      contract = hv.fetch("motivo_visita").flat_map do |group|
        group.fetch("items").map { |item| [ group.fetch("group"), group.fetch("label"), item.fetch("code"), item.fetch("label") ] }
      end
      expect(contract).to eq(api)
      expect(contract.size).to eq(37)
    end

    it "desfecho, turno, tipo_glicemia e tipo_de_imovel (texto, Q26)" do
      %i[desfecho turno tipo_glicemia tipo_de_imovel].each do |key|
        expect(contract_pairs(hv.fetch(key.to_s))).to eq(pairs(HomeVisits::Json.domains.fetch(key))), key.to_s
      end
      expect(hv.fetch("tipo_de_imovel").map { |row| row["code"] }).to match_array(TerritoryRegistry::Catalog::PROPERTY_TYPES)
      expect(hv.fetch("desfecho").map { |row| row["code"] }).to eq(HomeVisits::Catalog::OUTCOMES.keys)
    end

    it "atribuição: os CBOs da Tabela 7 registram; só o ACS fora de área" do
      expect(hv_rules.fetch("registrar_cbos")).to match_array(HomeVisits::Catalog::HOME_VISIT_CBOS.to_a)
      expect(hv_rules.fetch("out_of_area_cbos")).to eq([ HomeVisits::Catalog::ACS_CBO ])
    end

    it "regras cruzadas do §3 (YAML e constantes do HomeVisits::Catalog)" do
      rules = yaml.dig("home_visit", "rules")
      %w[non_residential_property_types non_residential_reasons male_forbidden_reasons outcomes_without_reasons_and_measurements
         without_person_allowed_reasons without_person_forbidden_measurements responsible_document_reasons reasons_max visits_per_sheet].each do |key|
        expect(hv_rules.fetch(key)).to eq(rules.fetch(key)), key
      end
      expect(hv_rules.fetch("non_residential_property_types")).to match_array(HomeVisits::Catalog::NON_RESIDENTIAL)
      expect(hv_rules.fetch("non_residential_reasons")).to match_array(HomeVisits::Catalog::NON_RESIDENTIAL_REASONS)
      expect(hv_rules.fetch("male_forbidden_reasons")).to eq(HomeVisits::Catalog::MALE_FORBIDDEN_REASONS)
      expect(hv_rules.fetch("without_person_allowed_reasons")).to eq(HomeVisits::Catalog::WITHOUT_PERSON_ALLOWED_REASONS)
      expect(hv_rules.fetch("responsible_document_reasons")).to eq(HomeVisits::Catalog::RESPONSIBLE_DOCUMENT_REASONS)
      expect(hv_rules.fetch("visits_per_sheet")).to eq(HomeVisits::Catalog::MAX_VISITS_PER_SHEET)
      expect(hv_rules.fetch("note_max_length")).to eq(HomeVisits::Catalog::NOTE_MAX)
      expect(hv_rules.fetch("withdrawal_reason_length")).to eq("min" => HomeVisits::Catalog::WITHDRAWAL_REASON.min,
                                                               "max" => HomeVisits::Catalog::WITHDRAWAL_REASON.max)
      expect(hv_rules.dig("unidentified_patient", "error")).to eq("patient_unidentified")
    end

    it "medidas: faixa, casas, par obrigatório e campo LEDI" do
      api = yaml.dig("home_visit", "measurements")
      expect(hv_rules.fetch("measurements").keys).to match_array(api.keys)
      expect(hv_rules.fetch("measurements").keys).to match_array(HomeVisits::Catalog::MEASUREMENTS.keys)
      hv_rules.fetch("measurements").each do |key, rule|
        expect(rule.slice("min", "max", "decimals", "requires", "ledi")).to eq(api.fetch(key).slice("min", "max", "decimals", "requires", "ledi")), key
        range, decimals = HomeVisits::Catalog::MEASUREMENTS.fetch(key)
        expect([ range&.min, range&.max ]).to eq([ rule["min"], rule["max"] ]), key
        expect(decimals).to eq(rule.fetch("decimals", 0)), key
      end
    end

    it "turno pelo relógio da cidade (HomeVisits::Rules.shift)" do
      day = Time.zone.local(2026, 11, 10)
      start = day
      hv_rules.fetch("shift_from_local_time").each do |row|
        hour, minute = row.fetch("before").split(":").map(&:to_i)
        limit = day + hour.hours + minute.minutes
        expect(HomeVisits::Rules.shift(start)).to eq(row.fetch("shift"))
        expect(HomeVisits::Rules.shift(limit - 1.minute)).to eq(row.fetch("shift"))
        start = limit
      end
    end
  end

  describe "atividade coletiva" do
    it "domínios: códigos, rótulos e ordem" do
      api = CollectiveActivities::Json.domains
      { "tipo_atividade_coletiva" => :activity_types, "temas_para_reuniao" => :meeting_topics, "publico_alvo" => :target_audience,
        "temas_para_saude" => :health_topics, "praticas_em_saude" => :health_practices, "outro_procedimento_coletivo" => :procedures }.each do |contract, key|
        expect(contract_pairs(ca.fetch(contract))).to eq(pairs(api.fetch(key))), contract
      end
      expect(ca.fetch("tipo_atividade_coletiva").map { |row| row["code"] }).to eq(CollectiveActivities::Catalog::TYPES.to_a)
    end

    it "campos por tipo (with_meeting_topic_6 = proibido salvo com o tema de reunião 6)" do
      exception = "with_meeting_topic_#{CollectiveActivities::Rules::MEETING_EXCEPTION}"
      api = CollectiveActivities::Rules::BY_TYPE.to_h do |type, row|
        fields = row.to_h do |field, value|
          meeting = CollectiveActivities::Catalog::MEETING_TYPES.include?(type)
          [ field, field == "health_topics" && meeting && value == "forbidden" ? exception : value ]
        end
        [ type.to_s, fields ]
      end
      expect(ca_rules.fetch("by_activity_type")).to eq(api)
      expect(ca_rules.fetch("values").keys).to match_array(api.values.flat_map(&:values).uniq)
    end

    it "regras cruzadas do §4" do
      expect(ca_rules.fetch("practices_only_in_activity_type")).to eq("6" => CollectiveActivities::Catalog::PRACTICE_TYPE6_ONLY)
      expect(CollectiveActivities::Rules::TYPE6_ONLY).to eq(CollectiveActivities::Catalog::PRACTICE_TYPE6_ONLY)
      expect(ca_rules.fetch("procedure_code_with_practice")).to eq(CollectiveActivities::Catalog::PROCEDURE_PRACTICE)
      expect(ca_rules.fetch("smoking_with_practices")).to eq(CollectiveActivities::Catalog::SMOKING_PRACTICES)
      expect(ca_rules.fetch("pse_only_health_topics")).to eq(CollectiveActivities::Catalog::FORBIDDEN_HEALTH_TOPICS)
      expect(ca_rules.fetch("list_max")).to eq(CollectiveActivities::Rules::LIST_MAX)
      expect(ca_rules.fetch("participants_count")).to eq("min" => CollectiveActivities::Catalog::COUNT.min,
                                                         "max" => CollectiveActivities::Catalog::COUNT.max)
      expect(ca_rules.fetch("participants_required_identifier_types")).to eq(CollectiveActivities::Catalog::PARTICIPANTS_REQUIRED)
      expect(ca_rules.fetch("participants_required_identifier_types"))
        .to eq(yaml.dig("collective_activity", "rules", "participant_identifier_types"))
      expect(ca_rules.fetch("place_text_max_length")).to eq(CollectiveActivities::Catalog::PLACE_TEXT_MAX)
      expect(ca_rules.fetch("mistaken_reason_length")).to eq("min" => CollectiveActivities::Catalog::MISTAKEN_REASON.min,
                                                             "max" => CollectiveActivities::Catalog::MISTAKEN_REASON.max)
      ca_rules.fetch("participant_measurements").each do |key, rule|
        expect(rule).to eq(CollectiveActivities::Rules::PARTICIPANT_MEASUREMENTS.fetch(key).slice("min", "max", "decimals", "ledi")), key
      end
      expect(ca_rules.fetch("participant_measurements").keys).to match_array(CollectiveActivities::Rules::PARTICIPANT_MEASUREMENTS.keys)
      expect(ca_rules.dig("unidentified_patient", "error")).to eq("patient_unidentified")
    end
  end

  it "pessoa: sexo e justificativa sem CPF do 24a" do
    expect(domains.dig("patient", "sexo").map { |row| row["code"] }).to match_array(TerritoryRegistry::Catalog::SEX_TO_LEDI.keys)
    expect(domains.dig("patient", "justificativa_nao_possui_cpf", "codes")).to eq(TerritoryRegistry::Catalog::NO_CPF_REASONS)
  end

  describe "códigos de erro" do
    it "errors.http tem todo código que a borda do app de campo responde" do
      expect(domains.dig("errors", "http")).to include(*FieldSync::Catalog::HTTP_ERRORS)
    end

    # Varredura do texto inteiro (a chamada pode quebrar linha depois do parêntese):
    # err(:x, refuse(:x, fail(:x e Result.fail(:x.
    it "errors.item tem todo código recusado pelas regras e pelos comandos de registro (Tasks 6–15)" do
      files = %w[app/services/home_visits/rules.rb app/services/home_visits/people.rb app/services/collective_activities/rules.rb
                 app/commands/home_visits/record.rb app/commands/home_visits/withdraw.rb app/commands/collective_activities/record.rb]
      codes = files.flat_map do |file|
        File.read(Rails.root.join(file), encoding: "utf-8").scan(/\b(?:err|refuse|fail)\(\s*:([a-z_]+)/m).flatten
      end.uniq
      expect(codes.size).to be >= 20
      expect(codes - domains.dig("errors", "item")).to eq([])
    end
  end
end
