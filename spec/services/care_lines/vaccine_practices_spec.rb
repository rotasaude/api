require "rails_helper"

# Módulo 29, Task 17 (contrato §10; §15 W5): as linhas de cuidado medem vacina
# com `vaccination` utilizável — `vaccine:<código>` pela dose ativa
# (transcrição inclusive, cancelada nunca) e `vaccine:c2_schedule` pela nota do
# C2. Caderneta não conferida → `unchecked` ("não conferido"): nunca pendência,
# fora do pior da linha, do contador de vencidos e do denominador da prévia.
RSpec.describe "CareLines: práticas de vacina" do
  let(:today) { Time.zone.today }

  describe CareLines::Evaluate do
    let(:entries) { CareLines::Templates::Load.entries.index_by { |e| e["key"] } }
    let(:lmp) { today - 200 }
    let(:mom) { CareLines::Person.new(birth_date: today - 10_000, sex: "female") }
    let(:checked) { { CareLines::Sources::VACCINE_CHECKED => [ CareLines::Event.new(on: today - 400) ] } }

    def practices(key) = CareLines::Rules.practices(entries.fetch(key)["practices"], template: true).payload[:practices]
    def c3_f(events:, **opts)
      described_class.call(practices: practices("pregnancy_c3"), person: mom, anchors: { "lmp" => lmp }, events: events, today: today, **opts)
                     .find { |s| s.key == "c3_f" }
    end

    it "com vaccination desligado a prática de vacina segue untracked" do
      expect(c3_f(events: checked)).to have_attributes(status: "untracked", tracked: false)
      expect(c3_f(events: checked, vaccination: false)).to have_attributes(status: "untracked", tracked: false)
    end

    it "ligado e sem conferência: unchecked, fora do pior da linha" do
      status = c3_f(events: { "vaccine:57" => [ CareLines::Event.new(on: today - 30) ] }, vaccination: true)
      expect(status).to have_attributes(status: "unchecked", tracked: false, met: false, due_on: nil, done_at: nil, count: nil)
      expect(described_class.worst([ status ])).to eq("untracked")
      ok = CareLines::PracticeStatus.new(key: "x", label: "x", citizen_label: nil, source: "consultation", tracked: true, status: "ok",
                                         done_at: nil, due_on: nil, count: 1, expected: 1, met: true, points: 1)
      expect(described_class.worst([ status, ok ])).to eq("ok")
    end

    it "conferida e com dTpa 57 na janela (a partir da 20ª semana): ok" do
      expect(c3_f(events: checked.merge("vaccine:57" => [ CareLines::Event.new(on: lmp + 150) ]), vaccination: true))
        .to have_attributes(status: "ok", tracked: true, met: true, done_at: lmp + 150)
      # Antes da 20ª semana não conta; sem dose e com a janela aberta: em aberto, nunca unchecked.
      expect(c3_f(events: checked.merge("vaccine:57" => [ CareLines::Event.new(on: lmp + 100) ]), vaccination: true))
        .to have_attributes(tracked: true, met: false)
    end

    it "a fonte de vacina só é pedida com vaccination ligado" do
      line = practices("pregnancy_c3").find { |p| p["key"] == "c3_f" }
      expect(described_class.sources_of(line)).to eq([])
      expect(described_class.sources_of(line, vaccination: true)).to eq([ "vaccine:57" ])
    end
  end

  describe CareLines::Rules do
    let(:base) do
      { "key" => "v", "label" => "Vacina", "anchor" => "rolling", "window_days" => 365, "min_count" => 1, "points" => 10 }
    end

    def field(source) = described_class.practices([ base.merge("source" => source) ]).then { |r| r.failure? ? r.details[:field] : nil }

    it "vacina só com código do catálogo, sem zero à esquerda, ou o C2" do
      expect(field("vaccine:57")).to be_nil
      expect(field("vaccine:9")).to be_nil
      expect(field("vaccine:c2_schedule")).to be_nil
      expect(field("vaccine:09")).to eq("practices[0].source")
      expect(field("vaccine:999")).to eq("practices[0].source")
      expect(field("vaccine:checked")).to eq("practices[0].source")
    end

    it "catálogo-base: 57, 33 e 67 existem no catálogo de imunobiológicos com os nomes das notas" do
      expect(%w[57 33 67].map { |code| Vaccination::Immunobiologicals.find(code).name })
        .to eq([ "Vacina dTpa adulto", "Vacina influenza trivalente", "Vacina HPV quadrivalente" ])
    end
  end

  describe "fontes e avaliação no banco" do
    before do
      care_city!
      vaccination_city!
    end

    let(:unit) { care_unit! }
    let(:doctor) { care_doctor!(unit) }
    let!(:team) { care_team!(unit, doctor) }
    let(:room) { vaccine_room! }

    def at(date) = Time.zone.local(date.year, date.month, date.day, 10)
    def dose!(patient, code, on, **over) = create_immunization!(room, patient: patient, immunobiological_code: code, applied_at: at(on), **over)
    def check!(patient) = VaccinationRecordCheck.create!(patient: patient, mode: "confirmed_complete", checked_by_user: room_member!(room),
                                                         vaccine_room: room, checked_at: Time.current)

    def practice(enrollment, key, vaccination: true)
      CareLines::Evaluation.enrollments([ enrollment ], today: today, vaccination: vaccination).fetch(enrollment.id).practices.find { |p| p.key == key }
    end

    it "dTpa: transcrição conta, cancelada não; sem conferência é unchecked" do
      mom = vaccine_patient!(birth_date: today - 10_000, sex: "female")
      lmp = today - 200
      enrollment = care_enrollment!(patient: mom, line: adopted_line!("pregnancy_c3"), team: team, by: doctor, anchor_date: lmp)
      dose!(mom, "57", lmp + 150, cancelled_at: Time.current, cancelled_by_user: room_member!(room), cancel_reason: "Registrada na pessoa errada")

      expect(practice(enrollment, "c3_f", vaccination: false)).to have_attributes(status: "untracked")
      expect(practice(enrollment, "c3_f")).to have_attributes(status: "unchecked", tracked: false)

      check!(mom)
      expect(practice(enrollment, "c3_f")).to have_attributes(tracked: true, met: false, count: 0)

      dose!(mom, "57", lmp + 160, transcription: true, stock_lot: nil)
      expect(practice(enrollment, "c3_f")).to have_attributes(status: "ok", tracked: true, met: true, done_at: lmp + 160)
    end

    it "C2 pela nota metodológica: fecha no dia da última dose que completa o esquema" do
      birth = today - 600
      child = vaccine_patient!(birth_date: birth, sex: "male")
      check!(child)
      enrollment = care_enrollment!(patient: child, line: adopted_line!("child_c2"), team: team, by: doctor)
      [ [ "42", 60 ], [ "43", 120 ], [ "42", 180 ], [ "22", 61 ], [ "22", 151 ], [ "26", 60 ], [ "26", 120 ], [ "24", 300 ], [ "24", 370 ]
      ].each { |code, day| dose!(child, code, birth + day) }
      expect(practice(enrollment, "c2_e")).to have_attributes(tracked: true, met: false, count: 0)

      dose!(child, "56", birth + 450, transcription: true, stock_lot: nil)
      expect(practice(enrollment, "c2_e")).to have_attributes(status: "ok", tracked: true, met: true, done_at: birth + 450, count: 1)
    end

    it "contador de vencidos: unchecked não conta; conferida sem influenza conta; transcrição resolve" do
      base = adopted_line!("elderly_c6")
      flu_only = CareLine.create!(source: "custom", name: "Só influenza", eligibility: base.eligibility,
                                  practices: base.practices.select { |p| p["key"] == "c6_d" }, updated_by_user: care_admin!)
      elder = vaccine_patient!(birth_date: today - 27_000, sex: "female")
      enrollment = care_enrollment!(patient: elder, line: flu_only, team: team, by: doctor, enrolled_at: 400.days.ago)
      row = -> { CareLines::Evaluation.enrollments([ enrollment ], today: today, vaccination: true).fetch(enrollment.id) }

      expect(row.call.worst).to eq("untracked")
      expect(CareLines::Board.overdue_count(team, today: today, vaccination: true)).to eq(0)
      expect(CareLines::Board.page(team: team, line_id: nil, status: "overdue", before: nil, limit: 10, today: today, vaccination: true)[:rows])
        .to be_empty

      check!(elder)
      expect(row.call.worst).to eq("overdue")
      expect(CareLines::Board.overdue_count(team, today: today, vaccination: true)).to eq(1)

      dose!(elder, "33", today - 100, transcription: true, stock_lot: nil)
      expect(row.call.worst).to eq("ok")
      expect(CareLines::Board.overdue_count(team, today: today, vaccination: true)).to eq(0)
    end

    it "prévia: unchecked sai do denominador da prática; a vacina deixa de ser excluída" do
      care_lines_loaded!
      neighborhood = care_neighborhood!(unit)
      care_citizen!(age: 12, sex: "female", neighborhood: neighborhood) # sem paciente: caderneta não conferida
      girl = care_patient!(age: 12, sex: "female", problems: [ %w[ciap2 K86] ], unit: unit, doctor: doctor)
      check!(girl)
      dose!(girl, "67", Date.iso8601(girl.birth_date) + 3700)

      on = CareLines::Preview.call(team: team, indicator: "C7", today: today, vaccination: true)
      expect(on[:excluded]).to eq([])
      expect(on[:practices].find { |p| p[:key] == "c7_b" }).to include(tracked: true, achieved: 1, denominator: 1)

      off = CareLines::Preview.call(team: team, indicator: "C7", today: today)
      expect(off[:excluded]).to eq(%w[vaccine])
      expect(off[:practices].find { |p| p[:key] == "c7_b" }).to include(tracked: false, weight: "0.0")
    end
  end
end
