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
      expect(hv_rules.fetch("measurements").keys).to match_array(HomeVisits::Rules::MEASUREMENTS.keys)
      hv_rules.fetch("measurements").each do |key, rule|
        expect(rule.slice("min", "max", "decimals", "requires", "ledi")).to eq(api.fetch(key).slice("min", "max", "decimals", "requires", "ledi")), key
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

    # v1.3.0 (contracts Task 6, Q3): as sete chaves de regra são as de
    # CollectiveActivities::Json.domains[:rules], na forma em que o api as serve
    # (sem o campo LEDI das medidas).
    it "regras na forma que o api serve (as sete chaves de CollectiveActivities::Json.domains)" do
      keys = %w[list_max by_type health_topics_with_meeting_topic practices_only_in_type procedure_practices smoking_practices
                participant_measurements]
      api = JSON.parse(CollectiveActivities::Json.domains.fetch(:rules).to_json)
      expect(api.keys).to eq(keys)
      expect(ca_rules.slice(*keys)).to eq(api)
      expect(ca_rules.fetch("participant_measurements").values.flat_map(&:keys)).not_to include("ledi")
      expect(ca_rules.fetch("values").keys).to match_array(api.fetch("by_type").values.flat_map(&:values).uniq)
    end

    it "regras cruzadas do §4" do
      expect(ca_rules.fetch("practices_only_in_type")).to eq([ { "type" => 6, "practices" => CollectiveActivities::Catalog::PRACTICE_TYPE6_ONLY } ])
      expect(CollectiveActivities::Rules::TYPE6_ONLY).to eq(CollectiveActivities::Catalog::PRACTICE_TYPE6_ONLY)
      expect(ca_rules.fetch("procedure_practices")).to eq([ CollectiveActivities::Catalog::PROCEDURE_PRACTICE ])
      expect(ca_rules.fetch("smoking_practices")).to eq(CollectiveActivities::Catalog::SMOKING_PRACTICES)
      expect(ca_rules.fetch("health_topics_with_meeting_topic")).to eq([ CollectiveActivities::Rules::MEETING_EXCEPTION ])
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
        expect(rule).to eq(CollectiveActivities::Rules::PARTICIPANT_MEASUREMENTS.fetch(key).slice("min", "max", "decimals")), key
      end
      expect(ca_rules.fetch("participant_measurements").keys).to match_array(CollectiveActivities::Rules::PARTICIPANT_MEASUREMENTS.keys)
      expect(ca_rules.dig("unidentified_patient", "error")).to eq("patient_unidentified")
    end
  end

  # Módulo 35a (§3, §6, §13; Q7(3), Q16(f)): os domínios e limites do
  # vector_control são os do VectorControl::Catalog e do
  # config/vector_control/domains.yml (códigos, rótulos e ORDEM).
  describe "vigilância ambiental (vector_control, v1.3.0)" do
    let(:vector) { domains.fetch("vector_control") }
    let(:labels) { YAML.load_file(Rails.root.join("config/vector_control/domains.yml")) }

    it "as seis listas do domains.yml: códigos, rótulos e ordem" do
      lists = %w[activities work_types situations deposit_groups measure_methods risk_classes]
      expect(vector.slice(*lists)).to eq(labels.slice(*lists))
      expect(labels.keys).to match_array(lists)
      expect(vector.slice(*lists).transform_values { |rows| rows.map { _1["code"] } }).to eq(
        "activities" => VectorControl::Catalog::ACTIVITIES, "work_types" => VectorControl::Catalog::WORK_TYPES,
        "situations" => VectorControl::Catalog::SITUATIONS, "deposit_groups" => VectorControl::Catalog::DEPOSIT_GROUPS,
        "measure_methods" => VectorControl::Catalog::METHODS, "risk_classes" => VectorControl::Catalog::RISK_CLASSES
      )
      expect(JSON.parse(VectorControl::Json.domains.slice(*lists.map(&:to_sym)).to_json)).to eq(vector.slice(*lists))
    end

    it "os códigos das outras listas são os do Catalog (unidade, condição, situação da ovitrampa, item e bloqueio)" do
      codes = vector.slice("product_units", "ovitrap_conditions", "ovitrap_statuses", "liraa_item_statuses", "transmission_block_statuses")
                    .transform_values { |rows| rows.map { _1["code"] } }
      expect(codes).to eq("product_units" => VectorControl::Catalog::UNITS, "ovitrap_conditions" => VectorControl::Catalog::CONDITIONS,
                          "ovitrap_statuses" => Ovitrap::STATUSES, "liraa_item_statuses" => LiraaDrawItem::STATUSES + %w[closed],
                          "transmission_block_statuses" => %w[active closed])
      expect(VectorControl::Catalog::BLOCK_STATUSES).to include(*codes.fetch("transmission_block_statuses"))
    end

    it "limits = Catalog::LIMITS (Q7(3)) e as regras numéricas do §3" do
      expect(vector.fetch("limits")).to eq(VectorControl::Catalog::LIMITS.stringify_keys)
      expect(VectorControl::Json.domains.fetch(:limits)).to eq(VectorControl::Catalog::LIMITS)
      rules = vector.fetch("rules")
      expect(rules.fetch("registrar_cbos")).to eq([ TerritoryRegistry::Catalog::ENDEMIC_AGENT_CBO ])
      expect(rules.fetch("situation_outcome")).to eq(VectorControl::Catalog::SITUATION_OUTCOME)
      expect(rules.fetch("activity_property_types")).to eq("pe" => [ VectorControl::Catalog::PE_PROPERTY ],
                                                           "ie" => VectorControl::Catalog::IE_PROPERTIES)
      expect(rules.fetch("activity_links")).to eq(VectorControl::Catalog::LINKED_ACTIVITIES)
      expect(rules.dig("times", "max_hours")).to eq(VectorControl::Catalog::INSPECTION_MAX / 1.hour)
      expect(rules.fetch("derived_reasons").keys.map(&:to_i)).to eq(VectorControl::Catalog::DERIVED_REASONS)
      expect(rules.fetch("sample_label_collision")).to eq("sample_label_taken")
    end
  end

  # Módulo 35b, Task 17 (contrato §11, §12; Q20, Q29, Q36): a seção zoonoses
  # do domains-v1.json é a do config/zoonoses/domains.yml (rótulos, códigos e
  # ORDEM), dos limites do Zoonoses::Json.domains e das constantes do
  # Zoonoses::Catalog; os dez códigos novos estão em errors.item, e todo código
  # que os comandos chamados pelo app recusam também.
  describe "centro de zoonoses (zoonoses, v1.4.0)" do
    let(:zoonoses) { domains.fetch("zoonoses") }
    let(:labels) { YAML.load_file(Rails.root.join("config/zoonoses/domains.yml")) }

    it "as listas: rótulos, códigos e ordem do domains.yml e do Catalog" do
      lists = %w[species sexes sizes animal_statuses dpp_results leish_survey_kinds product_uses]
      expect(zoonoses.keys).to match_array(lists + %w[limits rules])
      expect(zoonoses.slice(*lists)).to eq(labels.slice(*lists).transform_values { |rows| rows.map { _1.transform_values(&:to_s) } })
      expect(zoonoses.slice(*lists).transform_values { |rows| rows.map { _1["code"] } }).to eq(
        "species" => Zoonoses::Catalog::SPECIES, "sexes" => Zoonoses::Catalog::SEXES, "sizes" => Zoonoses::Catalog::SIZES,
        "animal_statuses" => Zoonoses::Catalog::ANIMAL_STATUSES, "dpp_results" => Zoonoses::Catalog::DPP_RESULTS,
        "leish_survey_kinds" => Zoonoses::Catalog::SURVEY_KINDS, "product_uses" => Zoonoses::Catalog::PRODUCT_USES
      )
    end

    it "limits = os do Zoonoses::Json.domains (Catalog) e as regras do §11/§12" do
      expect(zoonoses.fetch("limits")).to eq(Zoonoses::Json.domains.fetch(:limits).stringify_keys)
      expect(zoonoses.dig("limits", "microchip_digits")).to eq(15)
      expect("9" * 15).to match(Zoonoses::Catalog::MICROCHIP)
      rules = zoonoses.fetch("rules")
      expect(rules.fetch("registrar_cbos")).to eq(Zoonoses::Catalog::FIELD_CBOS)
      expect(rules.fetch("leish_collection_cbos")).to eq([ TerritoryRegistry::Catalog::ENDEMIC_AGENT_CBO ])
      expect(rules.fetch("dog_only")).to match_array(%w[leish_collection collar])
      expect(rules.fetch("vaccination_modality")).to eq("house")
      expect(Zoonoses::Catalog::MODALITIES).to include("house")
      expect(rules.fetch("collar_due_window_days")).to eq(Zoonoses::Catalog::COLLAR_DUE_WINDOW)
      expect(rules.fetch("adverse_note_requires_event")).to be(true)
      expect(rules.fetch("microchip_on_create_only")).to eq(Zoonoses::SaveAnimal::CREATE_ONLY.include?("microchip"))
      expect(rules.fetch("stock_shortfall_rejects")).to be(false)
      label = JSON.parse(File.read(FieldSync::Schemas::DIR.join("upload-response-v1.json"))).dig("$defs", "result", "properties", "label", "pattern")
      expect(label).to eq(Zoonoses::Catalog::LABEL.source.sub('\\A', "^").sub('\\z', "$").gsub('\\d', "[0-9]"))
      expect(FieldSync::Catalog::ITEM_TYPES.last(4)).to eq(%w[animal rabies_vaccination leish_collection collar])
      expect(FieldSync::Upload::RESULT_TYPES.values_at(*FieldSync::Catalog::ITEM_TYPES.last(4))).to eq(%w[Animal RabiesVaccination LeishTest Collar])
    end

    it "errors.item tem os dez códigos novos e todo código que os comandos chamados pelo app recusam" do
      novos = %w[microchip_taken registry_number_taken already_vaccinated_in_campaign campaign_not_open survey_not_open animal_not_dog
                 animal_not_active date_out_of_range household_not_in_survey tutor_not_found]
      expect(novos.size).to eq(10)
      expect(novos - domains.dig("errors", "item")).to eq([])
      files = %w[app/commands/zoonoses/save_animal.rb app/commands/zoonoses/record_vaccination.rb app/commands/zoonoses/record_leish_test.rb
                 app/commands/zoonoses/place_collar.rb]
      codes = files.flat_map do |file|
        source = File.read(Rails.root.join(file), encoding: "utf-8")
        source.scan(/\bfail\(\s*:([a-z_]+)/m).flatten + source.scan(/\? :([a-z_]+) : :([a-z_]+)/).flatten + source.scan(/\[ :([a-z_]+_taken),/).flatten
      end.uniq
      expect(codes).to include("microchip_taken", "registry_number_taken", "cbo_not_allowed", "household_not_in_survey")
      # Só do dashboard (o app nunca chega nelas): o papel, a correção do
      # teste, o ELISA e a versão esperada; animal_changed vira stale_version.
      dashboard_only = %w[missing_role expected_version_required test_changed elisa_without_reactive_dpp animal_changed]
      expect(codes - dashboard_only - domains.dig("errors", "item")).to eq([])
    end
  end

  it "pessoa: sexo e justificativa sem CPF do 24a" do
    expect(domains.dig("patient", "sexo").map { |row| row["code"] }).to match_array(TerritoryRegistry::Catalog::SEX_TO_LEDI.keys)
    expect(domains.dig("patient", "justificativa_nao_possui_cpf", "codes")).to eq(TerritoryRegistry::Catalog::NO_CPF_REASONS)
  end

  describe "coordenada e catálogo do 24c (ADR 0053)" do
    it "location: os limites do §4 e da Q3 são os do FieldLocation" do
      location = domains.fetch("location")
      expect(location).to include("decimals" => FieldLocation::DECIMALS)
      expect(location.fetch("latitude")).to eq("min" => -90, "max" => 90)
      expect(location.fetch("longitude")).to eq("min" => -180, "max" => 180)
      expect(location.fetch("accuracy_m")).to eq("min" => 0, "max" => 10_000, "decimals" => FieldLocation::ACCURACY_DECIMALS,
                                                 "required_for" => FieldLocation::ACCURACY_REQUIRED_SOURCES)
      expect(location.fetch("sources")).to match_array(FieldLocation::SOURCES)
      expect(location.fetch("visit_sources")).to match_array(FieldLocation::VISIT_SOURCES)
      expect([ FieldLocation::LATITUDE, FieldLocation::LONGITUDE, FieldLocation::ACCURACY ]).to eq([ (-90..90), (-180..180), (0..10_000) ])
    end

    it "o item family entra no catálogo e no livro de idempotência" do
      # O 35a (W-4) acrescenta os itens de ovitrampa depois de family.
      expect(FieldSync::Catalog::ITEM_TYPES.index("family")).to eq(6)
      receipt = FieldSyncReceipt.new(item_type: "family")
      receipt.valid?
      expect(receipt.errors[:item_type]).to be_empty
    end

    it "motivos de revogação: device_revoked só para user e admin (Q17)" do
      expect(FieldSync::Catalog::REVOKED_REASONS).to eq(%w[user admin replaced membership_ended user_disabled])
      expect(FieldSync::Catalog::SUSPENDED_REASONS).to eq(%w[replaced membership_ended user_disabled])
      expect(FieldSync::Catalog::REVOKED_REASONS - FieldSync::Catalog::SUSPENDED_REASONS).to eq(%w[user admin])
      # Com autor: o dono, o administrador e a substituição (feita pelo dono).
      expect(FieldSync::Catalog::REVOKED_BY_PERSON).to eq(%w[user admin replaced])
    end

    it "a coordenada nunca vai ao log de parâmetros" do
      filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
      filtered = filter.filter("location" => { "latitude" => -25.42847123 }, "latitude" => 1, "longitude" => 2, "accuracy_m" => 3)
      expect(filtered.values).to all(eq("[FILTERED]"))
    end
  end

  describe "códigos de erro" do
    it "errors.http tem todo código que a borda do app de campo responde" do
      expect(domains.dig("errors", "http")).to include(*FieldSync::Catalog::HTTP_ERRORS)
    end

    it "códigos novos do 24c em errors.http e errors.item (Q8, Q9)" do
      expect(FieldSync::Catalog::HTTP_ERRORS).to include("device_suspended", "map_not_found", "range_not_satisfiable")
      expect(domains.dig("errors", "http")).to include("device_suspended", "map_not_found", "range_not_satisfiable")
      expect(domains.dig("errors", "item")).to include("invalid_location", "family_not_found", "cpf_or_reason_required")
    end

    # Lê os literais da borda da cidade: código novo ali sem entrada em
    # errors.http quebra este exemplo (Q8).
    it "os códigos de borda da cidade que o /field/v1 devolve estão em errors.http (Q8)" do
      source = File.read(Rails.root.join("app/controllers/concerns/city_resolution.rb"), encoding: "utf-8")
      codes = source.scan(/error: "([a-z_]+)"/).flatten.uniq
      expect(codes).to include("unknown_city", "city_suspended", "city_schema_behind")
      expect(codes - domains.dig("errors", "http")).to eq([])
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

    # Módulo 35a (§17; Q7(1), Q13(2)): os 21 códigos novos do boletim e da
    # ovitrampa, e todo código que as regras e os comandos do 35a recusam no
    # envio do app.
    it "errors.item tem os 21 códigos novos do 35a e os que as regras e os comandos dele recusam" do
      novos = %w[vector_inspection_invalid situation_outcome_mismatch inspection_not_worked activity_property_mismatch liraa_item_not_found
                 transmission_block_not_active deposit_counts_inconsistent product_not_allowed samples_exceed_larvae inspection_times_invalid
                 reason_derived block_already_set household_without_neighborhood block_not_in_household_neighborhood household_without_block
                 consent_required ovitrap_number_taken collection_out_of_range reading_not_open ovitrap_not_active sample_label_taken]
      expect(novos.size).to eq(21)
      expect(novos - domains.dig("errors", "item")).to eq([])
      files = %w[app/services/vector_control/inspection_rules.rb app/commands/vector_control/record_inspection.rb
                 app/commands/vector_control/install_ovitrap.rb app/commands/vector_control/collect_ovitrap.rb]
      codes = files.flat_map do |file|
        File.read(Rails.root.join(file), encoding: "utf-8").scan(/\b(?:err|refuse|fail|fail_with)\(\s*:([a-z_]+)/m).flatten
      end.uniq
      expect(codes).to include("sample_label_taken", "consent_required", "vector_inspection_invalid")
      expect(codes - domains.dig("errors", "item")).to eq([])
    end

    # Os códigos que o envio do app (Task 20) devolve por conta própria,
    # inclusive os da Q63 (internal_error, household_changed).
    it "errors.item tem todo código que o FieldSync::Upload recusa por conta própria (Q63)" do
      source = File.read(Rails.root.join("app/services/field_sync/upload.rb"), encoding: "utf-8")
      codes = source.scan(/\brejected\(\s*"([a-z_]+)"/m).flatten.uniq
      expect(codes).to include("internal_error", "household_changed", "client_uuid_conflict", "not_found")
      expect(codes - domains.dig("errors", "item")).to eq([])
    end
  end
end
