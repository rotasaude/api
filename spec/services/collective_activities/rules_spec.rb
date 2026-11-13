require "rails_helper"

# Módulo 24b (ADR 0052; contrato §4, §7, §11; Q15, Q32, Q36–Q38; plano, Task
# 13; pre-flight "| 13 |"): as regras cruzadas da atividade coletiva, puras e
# dirigidas por config/ledi/visit_activity_dictionaries.yml
# (`collective_activity.rules`). Corpo plano do §7 (Q15): lista ausente = vazia.
# Uma linha da tabela do §4 por exemplo; o banco (unidade ativa com CNES,
# profissionais, pacientes) fica com o CollectiveActivities::Record.
RSpec.describe CollectiveActivities::Rules, type: :model do
  let(:today) { Date.new(2026, 11, 12) }
  let(:rules) { described_class::RULES }

  # Tipo 5 (Atendimento em grupo) válido, com um participante.
  def body(**over)
    { "client_uuid" => SecureRandom.uuid, "team_id" => SecureRandom.uuid, "held_on" => today.iso8601, "shift" => 1,
      "activity_type" => 5, "place_text" => "Salão paroquial", "participants_count" => 3, "target_audience" => [ 1 ],
      "health_topics" => [ 1 ], "participants" => [ { "patient_id" => SecureRandom.uuid } ] }.merge(over.stringify_keys)
  end

  def meeting(**over)
    body(activity_type: 1, meeting_topics: [ 1 ], target_audience: nil, health_topics: nil, participants: nil, **over)
  end

  def check(input) = described_class.check(input, today: today)
  def first(input) = check(input).first

  it "o corpo válido passa (tipo 5 e reunião)" do
    expect(check(body)).to eq([])
    expect(check(meeting)).to eq([])
  end

  describe "a tabela do §4, por tipo (YAML by_activity_type)" do
    it "reunião (1) exige meeting_topics e recusa target_audience" do
      expect(first(meeting(meeting_topics: []))).to eq(error: :invalid_collective_activity, path: "meeting_topics")
      expect(first(meeting(meeting_topics: nil))).to eq(error: :invalid_collective_activity, path: "meeting_topics")
      expect(first(meeting(target_audience: [ 1 ]))).to eq(error: :invalid_collective_activity, path: "target_audience")
      expect(first(meeting(health_practices: [ 20 ]))).to eq(error: :invalid_collective_activity, path: "health_practices")
    end

    it "reunião com tema 6 aceita health_topics; sem o 6 recusa" do
      expect(check(meeting(meeting_topics: [ 2, 6 ], health_topics: [ 1 ]))).to eq([])
      expect(check(meeting(meeting_topics: [ 6 ]))).to eq([])
      expect(first(meeting(meeting_topics: [ 2 ], health_topics: [ 1 ])))
        .to eq(error: :invalid_collective_activity, path: "health_topics")
    end

    it "tipo 5 sem participantes → path participants (tipo 6 idem; reunião e tipos 4/7 aceitam sem)" do
      expect(first(body(participants: []))).to eq(error: :invalid_collective_activity, path: "participants")
      expect(first(body(participants: nil))).to eq(error: :invalid_collective_activity, path: "participants")
      expect(first(body(activity_type: 6, health_topics: nil, health_practices: [ 20 ], participants: nil)))
        .to eq(error: :invalid_collective_activity, path: "participants")
      expect(check(body(activity_type: 4, participants: nil))).to eq([])
      expect(check(body(activity_type: 7, participants: []))).to eq([])
    end

    it "tipo 6 exige health_practices; health_topics opcional" do
      six = body(activity_type: 6, health_topics: nil, health_practices: [ 20 ])
      expect(check(six)).to eq([])
      expect(check(six.merge("health_topics" => [ 1 ]))).to eq([])
      expect(first(six.merge("health_practices" => []))).to eq(error: :invalid_collective_activity, path: "health_practices")
    end

    it "tipos 4, 5 e 7 exigem target_audience e health_topics; 4 e 7 recusam práticas; nenhum aceita meeting_topics" do
      [ 4, 5, 7 ].each do |type|
        expect(first(body(activity_type: type, target_audience: []))).to eq(error: :invalid_collective_activity, path: "target_audience")
        expect(first(body(activity_type: type, health_topics: []))).to eq(error: :invalid_collective_activity, path: "health_topics")
        expect(first(body(activity_type: type, meeting_topics: [ 1 ]))).to eq(error: :invalid_collective_activity, path: "meeting_topics")
      end
      [ 4, 7 ].each do |type|
        expect(first(body(activity_type: type, health_practices: [ 20 ])))
          .to eq(error: :invalid_collective_activity, path: "health_practices")
      end
      expect(check(body(health_practices: [ 20 ]))).to eq([])
    end

    it "cada célula required/forbidden do YAML é aplicada (dado, não código)" do
      lists = { "meeting_topics" => [ 1 ], "target_audience" => [ 1 ], "health_topics" => [ 1 ], "health_practices" => [ 20 ] }
      rules.fetch("by_activity_type").each do |type, row|
        row.each do |field, rule|
          next if field == "participants"

          input = body(activity_type: type.to_i, **lists.to_h { |key, value| [ key, row[key] == "required" ? value : nil ] })
          input["meeting_topics"] = [ 6 ] if row["meeting_topics"] == "required" # o 6 libera health_topics
          expect(check(input)).to eq([]), "tipo #{type}: o mínimo válido"
          case rule
          when "required" then expect(first(input.merge(field => []))).to eq(error: :invalid_collective_activity, path: field)
          when "forbidden"
            next if field == "health_topics" && input["meeting_topics"]&.include?(6)

            expect(first(input.merge(field => lists[field]))).to eq(error: :invalid_collective_activity, path: field)
          end
        end
      end
    end
  end

  it "prática 9 no tipo 5 → path health_practices[i] (2, 9 e 33 só no tipo 6)" do
    expect(first(body(health_practices: [ 20, 9 ]))).to eq(error: :invalid_collective_activity, path: "health_practices[1]")
    expect(first(body(health_practices: [ 33 ]))).to eq(error: :invalid_collective_activity, path: "health_practices[0]")
    expect(check(body(activity_type: 6, health_topics: nil, health_practices: [ 2, 9, 33 ]))).to eq([])
  end

  it "prática 30 sem SIGTAP → path procedure_code; SIGTAP sem prática 30 → recusado; só os 58 da lista fechada (Q37)" do
    code = described_class::PROCEDURES.first
    expect(described_class::PROCEDURES.size).to eq(58)
    expect(first(body(health_practices: [ 30 ]))).to eq(error: :invalid_collective_activity, path: "procedure_code")
    expect(first(body(procedure_code: code))).to eq(error: :invalid_collective_activity, path: "procedure_code")
    expect(first(body(health_practices: [ 30 ], procedure_code: "0301010072")))
      .to eq(error: :invalid_collective_activity, path: "procedure_code")
    expect(first(body(health_practices: [ 30 ], procedure_code: code.to_i)))
      .to eq(error: :invalid_collective_activity, path: "procedure_code")
    expect(check(body(health_practices: [ 30 ], procedure_code: code))).to eq([])
  end

  it "smoking sem prática 25–28 → path participants[0].smoking (a 34 não libera)" do
    smoker = [ { "patient_id" => SecureRandom.uuid, "smoking" => { "quit" => true, "dropped_out" => false } } ]
    expect(first(body(participants: smoker))).to eq(error: :invalid_collective_activity, path: "participants[0].smoking")
    expect(first(body(participants: smoker, health_practices: [ 34 ])))
      .to eq(error: :invalid_collective_activity, path: "participants[0].smoking")
    expect(check(body(participants: smoker, health_practices: [ 25 ]))).to eq([])
    odd = [ { "patient_id" => SecureRandom.uuid, "smoking" => { "quit" => "sim" } } ]
    expect(first(body(participants: odd, health_practices: [ 26 ])))
      .to eq(error: :invalid_collective_activity, path: "participants[0].smoking.quit")
  end

  it "tema 18 → path health_topics[i]" do
    expect(first(body(health_topics: [ 1, 18 ]))).to eq(error: :invalid_collective_activity, path: "health_topics[1]")
  end

  it "altered_count não vem no corpo: o api deriva da lista (Q38)" do
    expect(first(body(altered_count: 1))).to eq(error: :invalid_collective_activity, path: "altered_count")
    listed = [ { "patient_id" => SecureRandom.uuid, "altered_evaluation" => true },
               { "patient_id" => SecureRandom.uuid, "altered_evaluation" => false }, { "patient_id" => SecureRandom.uuid } ]
    expect(check(body(participants: listed))).to eq([])
    expect(described_class.altered_count(listed)).to eq(1)
    expect(described_class.altered_count(nil)).to eq(0)
    expect(first(body(participants: [ { "patient_id" => SecureRandom.uuid, "altered_evaluation" => "sim" } ])))
      .to eq(error: :invalid_collective_activity, path: "participants[0].altered_evaluation")
  end

  it "participants_count 1–999 e ≥ participantes listados" do
    expect(first(body(participants_count: 0))).to eq(error: :invalid_collective_activity, path: "participants_count")
    expect(first(body(participants_count: 1000))).to eq(error: :invalid_collective_activity, path: "participants_count")
    expect(first(body(participants_count: "3"))).to eq(error: :invalid_collective_activity, path: "participants_count")
    two = [ { "patient_id" => SecureRandom.uuid }, { "patient_id" => SecureRandom.uuid } ]
    expect(first(body(participants_count: 1, participants: two))).to eq(error: :invalid_collective_activity, path: "participants_count")
    expect(check(body(participants_count: 2, participants: two))).to eq([])
  end

  it "unidade e texto juntos → path place_text; nenhum → path place_health_unit_id; texto até 250, nunca cortado" do
    expect(first(body(place_health_unit_id: SecureRandom.uuid))).to eq(error: :invalid_collective_activity, path: "place_text")
    expect(first(body(place_text: nil))).to eq(error: :invalid_collective_activity, path: "place_health_unit_id")
    expect(first(body(place_text: "   "))).to eq(error: :invalid_collective_activity, path: "place_text")
    expect(first(body(place_text: "x" * 251))).to eq(error: :invalid_collective_activity, path: "place_text")
    expect(check(body(place_text: "é" * 250))).to eq([])
    expect(first(body(place_text: nil, place_health_unit_id: "unidade"))).to eq(error: :invalid_collective_activity, path: "place_health_unit_id")
    expect(check(body(place_text: nil, place_health_unit_id: SecureRandom.uuid))).to eq([])
  end

  it "data além do prazo → activity_date_out_of_range; no futuro também; malformada → invalid" do
    expect(first(body(held_on: (today + 1).iso8601))).to eq(error: :activity_date_out_of_range, path: "held_on")
    min = HomeVisits::Rules.min_date(today)
    expect(check(body(held_on: min.iso8601))).to eq([])
    expect(first(body(held_on: (min - 1).iso8601))).to eq(error: :activity_date_out_of_range, path: "held_on")
    expect(first(body(held_on: "12/11/2026"))).to eq(error: :invalid_collective_activity, path: "held_on")
    expect(first(body(held_on: "2026-02-30"))).to eq(error: :invalid_collective_activity, path: "held_on")
  end

  it "tamanhos máximos das listas (Q36), códigos do domínio, sem repetição" do
    { "meeting_topics" => 7, "target_audience" => 17, "health_topics" => 16, "health_practices" => 14 }.each do |list, max|
      expect(rules.dig("list_max", list)).to eq(max)
    end
    expect(first(meeting(meeting_topics: (1..8).to_a))).to eq(error: :invalid_collective_activity, path: "meeting_topics")
    expect(check(meeting(meeting_topics: (1..7).to_a))).to eq([])
    audience = described_class::DOMAINS.fetch("target_audience")
    expect(audience.size).to eq(19)
    expect(check(body(target_audience: audience.first(17)))).to eq([])
    expect(first(body(target_audience: audience.first(18)))).to eq(error: :invalid_collective_activity, path: "target_audience")
    expect(first(body(target_audience: [ 11 ]))).to eq(error: :invalid_collective_activity, path: "target_audience[0]")
    expect(first(body(target_audience: [ 1, 1 ]))).to eq(error: :invalid_collective_activity, path: "target_audience[1]")
    expect(first(body(target_audience: [ "1" ]))).to eq(error: :invalid_collective_activity, path: "target_audience[0]")
    expect(first(body(target_audience: 1))).to eq(error: :invalid_collective_activity, path: "target_audience")
  end

  describe "a mesma pessoa duas vezes na atividade → duplicate_participant em participants[i] (Ruling T13-DUP, Q53, Q54)" do
    def typed(**over)
      { "full_name" => "Benedita Alves Rocha", "birth_date" => "1951-03-08", "sex" => "female", "no_cpf_reason" => "3" }
        .merge(over.stringify_keys)
    end

    def with_cpf(cpf, **over) = typed(cpf: cpf, **over).except("no_cpf_reason")
    def twice(first, second) = body(participants: [ { "patient_id" => SecureRandom.uuid }, first, second ])
    def hard = { error: :duplicate_participant, path: "participants[2]", confirmable: false }
    def soft = { error: :duplicate_participant, path: "participants[2]", confirmable: true }
    def reviewed(item) = item.merge("duplicates_reviewed" => true)

    it "o mesmo patient_id → confirmable false, nem com duplicates_reviewed" do
      id = SecureRandom.uuid
      expect(first(twice({ "patient_id" => id }, { "patient_id" => id }))).to eq(hard)
      expect(first(twice({ "patient_id" => id }, reviewed({ "patient_id" => id })))).to eq(hard)
    end

    it "o mesmo CPF ou o mesmo CNS (com ou sem pontuação) → confirmable false, nem com duplicates_reviewed" do
      cpf = { "new_patient" => with_cpf("123.456.789-09") }
      same_cpf = { "new_patient" => with_cpf("12345678909", full_name: "Outra Pessoa") }
      expect(first(twice(cpf, same_cpf))).to eq(hard)
      expect(first(twice(cpf, reviewed(same_cpf)))).to eq(hard)
      cns = { "new_patient" => typed(cns: "700 0000 0000 0001") }
      same_cns = { "new_patient" => typed(full_name: "Outra Pessoa", birth_date: "1990-01-01", cns: "700000000000001") }
      expect(first(twice(cns, same_cns))).to eq(hard)
      expect(first(twice(cns, reviewed(same_cns)))).to eq(hard)
      # CPF de um igual ao do outro, mesmo que o outro também tenha CNS diferente.
      both = { "new_patient" => with_cpf("12345678909", cns: "700000000000002") }
      expect(first(twice(cpf, reviewed(both)))).to eq(hard)
    end

    it "nome + nascimento (+ mãe) sem documento igual → confirmable true; duplicates_reviewed no segundo libera" do
      plain = { "new_patient" => typed(mother_name: "Rita Rocha") }
      same = { "new_patient" => typed(full_name: "  benedita alves-ROCHA ", mother_name: "rita rocha") }
      expect(first(twice(plain, same))).to eq(soft)
      expect(check(twice(plain, reviewed(same)))).to eq([])
      expect(first(twice(reviewed(plain), same))).to eq(soft) # a marca é do participante recusado
    end

    it "a regra do Patients::Duplicates: mãe ausente num dos dois é parecido; CNS diferentes não separam; CPF só de um também não" do
      plain = { "new_patient" => typed }
      expect(first(twice(plain, { "new_patient" => typed(mother_name: "Rita Rocha") }))).to eq(soft)
      expect(first(twice({ "new_patient" => typed(cns: "700000000000001") }, { "new_patient" => typed(cns: "700000000000002") })))
        .to eq(soft)
      expect(first(twice({ "new_patient" => with_cpf("12345678909") }, plain))).to eq(soft)
    end

    it "pessoas diferentes passam: mãe diferente, outro nascimento, dois CPFs diferentes" do
      plain = { "new_patient" => typed(mother_name: "Rita Rocha") }
      expect(check(twice(plain, { "new_patient" => typed(mother_name: "Ana Rocha") }))).to eq([])
      expect(check(twice(plain, { "new_patient" => typed(birth_date: "1951-03-09", mother_name: "Rita Rocha") }))).to eq([])
      expect(check(twice({ "new_patient" => with_cpf("12345678909") }, { "new_patient" => with_cpf("98765432100") }))).to eq([])
    end
  end

  it "participante: patient_id ou new_patient (exatamente um), chaves conhecidas, medidas na faixa" do
    expect(first(body(participants: [ {} ]))).to eq(error: :invalid_collective_activity, path: "participants[0].patient_id")
    both = { "patient_id" => SecureRandom.uuid, "new_patient" => { "full_name" => "Ana" } }
    expect(first(body(participants: [ both ]))).to eq(error: :invalid_collective_activity, path: "participants[0].new_patient")
    expect(first(body(participants: [ { "patient_id" => "x" } ]))).to eq(error: :invalid_collective_activity, path: "participants[0].patient_id")
    expect(first(body(participants: [ { "patient_id" => SecureRandom.uuid, "cpf" => "1" } ])))
      .to eq(error: :invalid_collective_activity, path: "participants[0].cpf")
    expect(first(body(participants: [ "x" ]))).to eq(error: :invalid_collective_activity, path: "participants[0]")
    expect(check(body(participants: [ { "new_patient" => { "full_name" => "Ana" }, "duplicates_reviewed" => true } ]))).to eq([])
    expect(first(body(participants: [ { "new_patient" => { "full_name" => "Ana" }, "duplicates_reviewed" => "sim" } ])))
      .to eq(error: :invalid_collective_activity, path: "participants[0].duplicates_reviewed")

    measured = ->(values) { body(participants: [ { "patient_id" => SecureRandom.uuid, "measurements" => values } ]) }
    expect(check(measured[{ "weight_kg" => 72.1234, "height_cm" => 170.04 }])).to eq([])
    expect(first(measured[{ "weight_kg" => 0.4 }])).to eq(error: :invalid_collective_activity, path: "participants[0].measurements.weight_kg")
    expect(first(measured[{ "height_cm" => 251 }])).to eq(error: :invalid_collective_activity, path: "participants[0].measurements.height_cm")
    expect(first(measured[{ "systolic" => 120 }])).to eq(error: :invalid_collective_activity, path: "participants[0].measurements.systolic")
    expect(first(measured[[ 1 ]])).to eq(error: :invalid_collective_activity, path: "participants[0].measurements")
    expect(described_class.measurements({ "weight_kg" => 72.12345, "height_cm" => 170.04 })).to eq("weight_kg" => 72.123, "height_cm" => 170.0)
    expect(described_class.measurements({})).to be_nil
  end

  it "profissionais: lista de { professional_id }, sem repetição" do
    expect(check(body(professionals: [ { "professional_id" => SecureRandom.uuid } ]))).to eq([])
    id = SecureRandom.uuid
    expect(first(body(professionals: [ { "professional_id" => id }, { "professional_id" => id } ])))
      .to eq(error: :invalid_collective_activity, path: "professionals[1].professional_id")
    expect(first(body(professionals: [ { "professional_id" => "x" } ])))
      .to eq(error: :invalid_collective_activity, path: "professionals[0].professional_id")
    expect(first(body(professionals: [ { "professional_id" => id, "cbo" => "225125" } ])))
      .to eq(error: :invalid_collective_activity, path: "professionals[0].cbo")
    expect(first(body(professionals: { "professional_id" => id }))).to eq(error: :invalid_collective_activity, path: "professionals")
  end

  it "tipo, turno, chave desconhecida e ids malformados → invalid_collective_activity com o path" do
    expect(first(body(activity_type: 8))).to eq(error: :invalid_collective_activity, path: "activity_type")
    expect(first(body(activity_type: "5"))).to eq(error: :invalid_collective_activity, path: "activity_type")
    expect(first(body(shift: 4))).to eq(error: :invalid_collective_activity, path: "shift")
    expect(first(body(team_id: "equipe"))).to eq(error: :invalid_collective_activity, path: "team_id")
    expect(first(body(place: { "text" => "Praça" }))).to eq(error: :invalid_collective_activity, path: "place")
    expect(first(body("x" * 100 => 1))[:path].length).to eq(64)
  end

  it "nunca o valor no erro: só código e path" do
    error = first(body(place_text: "Rua das Flores, casa da Maria" * 10))
    expect(error.keys).to eq(%i[error path])
    expect(error.values.join).not_to include("Maria")
  end
end
