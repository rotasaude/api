require "rails_helper"
require Rails.root.join("lib/sigtap_sample").to_s

# Módulo 31 (Desvios 3 e 4; contrato §4, P3, P23): instrumento da ação e a
# crítica SIGTAP na hora, sobre a SIGTAP da competência do mês (local) da ação.
RSpec.describe Psychosocial::ActionRules do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(Time.zone.local(2026, 11, 18, 15, 0)) { example.run } }

  let!(:city) { psychosocial_city! }
  let(:caps) { caps! }
  let(:staff) { caps_staff!(caps, cbo: "251510") }
  let(:link) { Psychosocial::Access.link(staff, caps.id) }
  let(:enrollment) { enrollment!(caps, reference: staff, started_on: Date.new(2026, 10, 1)) }

  def input(**over)
    { sigtap_code: "0301080208", performed_at: 1.hour.ago, quantity: 1, authorization_number: nil,
      participants: [ participant(enrollment) ] }.merge(over)
  end

  def participant(enrollment) = { enrollment_id: enrollment.id, enrollment: enrollment, patient_id: enrollment.patient_id }

  def errors(result) = result[:problems].map { |p| p[:error] }

  describe Psychosocial::Instrument do
    it "09 com matriculado → RAAS; senão 02 → BPA-I; senão 01 → BPA-C (P3)" do
      expect(described_class.for(%w[02 09], enrolled: true)).to eq("raas_psi")
      expect(described_class.for(%w[02 09], enrolled: false)).to eq("bpa_i")
      expect(described_class.for(%w[01 09], enrolled: false)).to eq("bpa_c")
      expect(described_class.for(%w[01], enrolled: true)).to eq("bpa_c")
      expect(described_class.for(%w[09], enrolled: false)).to eq(:enrollment_required)
      expect(described_class.for(%w[06], enrolled: true)).to eq(:instrument_mismatch)
      expect(described_class.for([], enrolled: true)).to eq(:instrument_mismatch)
    end
  end

  it "ação dentro da regra: instrumento e nenhum problema" do
    result = described_class.problems(input, unit: caps, link: link, now: Time.current)
    expect(result).to eq(instrument: "raas_psi", problems: [])
  end

  it "código fora da SIGTAP da competência → instrument_mismatch em sigtap_code" do
    result = described_class.problems(input(sigtap_code: "0399999999"), unit: caps, link: link, now: Time.current)
    expect(result[:problems]).to eq([ { error: "instrument_mismatch", path: "sigtap_code" } ])
  end

  it "quantidade acima da máxima (0301080208, máx. 31) → quantity_exceeded; 31 passa" do
    expect(errors(described_class.problems(input(quantity: 32), unit: caps, link: link, now: Time.current))).to eq(%w[quantity_exceeded])
    expect(errors(described_class.problems(input(quantity: 31), unit: caps, link: link, now: Time.current))).to eq([])
  end

  it "BPA-I com dois pacientes → bpa_i_single_patient em participants; com um, passa" do
    two = [ { patient_id: caps_patient!.id }, { patient_id: caps_patient!.id } ]
    result = described_class.problems(input(sigtap_code: "0301080232", participants: two), unit: caps, link: link, now: Time.current)
    expect(result[:instrument]).to eq("bpa_i")
    expect(result[:problems]).to eq([ { error: "bpa_i_single_patient", path: "participants" } ])
    one = described_class.problems(input(sigtap_code: "0301080232", participants: two.first(1)), unit: caps, link: link, now: Time.current)
    expect(one).to eq(instrument: "bpa_i", problems: [])
  end

  it "matrícula fechada ou de outro CAPS → enrollment_required com o índice do participante" do
    foreign = enrollment!(caps!(modality: "caps_ad"))
    closed = enrollment!(caps, reference: staff)
    closed.update_columns(closed_on: Date.current, destination: "01", closed_by_user_id: staff.id)
    participants = input[:participants] + [ participant(foreign), participant(closed) ]
    result = described_class.problems(input(participants: participants), unit: caps, link: link, now: Time.current)
    expect(result[:problems]).to eq([ { error: "enrollment_required", path: "participants[1]", participant_index: 1 },
                                      { error: "enrollment_required", path: "participants[2]", participant_index: 2 } ])
  end

  it "matrícula iniciada depois da data local da ação → enrollment_required; no dia do início, vale" do
    later = enrollment!(caps, reference: staff, started_on: Date.new(2026, 11, 10))
    before = described_class.problems(input(performed_at: Time.zone.local(2026, 11, 9, 23, 30), participants: [ participant(later) ]),
                                      unit: caps, link: link, now: Time.current)
    expect(before[:problems]).to eq([ { error: "enrollment_required", path: "participants[0]", participant_index: 0 } ])
    same_day = described_class.problems(input(performed_at: Time.zone.local(2026, 11, 10, 0, 30), participants: [ participant(later) ]),
                                        unit: caps, link: link, now: Time.current)
    expect(same_day).to eq(instrument: "raas_psi", problems: [])
  end

  it "quantidade máxima nula (cache) não limita: 999 passa" do
    cache = Billing::SigtapCache.new
    allow(cache).to receive(:max_quantity).and_return(nil)
    expect(described_class.problems(input(quantity: 999), unit: caps, link: link, now: Time.current, cache: cache))
      .to eq(instrument: "raas_psi", problems: [])
  end

  it "a crítica lê a SIGTAP da competência do mês local da ação (release do mês anterior)" do
    previous = 1.month.ago.beginning_of_month + 10.hours
    cache = Billing::SigtapCache.new
    expect(cache).to receive(:release).with(previous.strftime("%Y%m")).at_least(:once).and_call_original
    described_class.problems(input(performed_at: previous), unit: caps, link: link, now: Time.current, cache: cache)
  end

  # Review Focus 4: release importada antes do módulo (máximo 9999/vazio e sem o
  # arquivo de atributos) — sem limite inventado.
  it "release sem quantidade máxima nem atributos não gera quantity_exceeded nem authorization_required" do
    old = Dir.mktmpdir do |dir|
      SigtapSample.write_to(dir, competence: "202001")
      FileUtils.rm(Dir.glob(File.join(dir, "rl_procedimento_detalhe*")))
      path = File.join(dir, "tb_procedimento.txt")
      columns = SigtapSample::LAYOUTS.fetch("tb_procedimento")
      offset = columns.take_while { |name, *| name != "QT_MAXIMA_EXECUCAO" }.sum { |_, size, _| size }
      lines = File.binread(path).split("\r\n").map do |line|
        line.start_with?("0301080208") ? line.dup.tap { |l| l[offset, 4] = "9999" } : line
      end
      File.binwrite(path, lines.join("\r\n") + "\r\n")
      Terminology::Import.call(kind: "sigtap", version: "202001", path: dir, by: "rspec")
    end
    expect(old).to be_ok
    release = old.payload[:release]
    expect(SigtapProcedure.find_by!(release_id: release.id, code: "0301080208").max_quantity).to be_nil
    expect(SigtapProcedureAttribute.where(release_id: release.id)).to be_empty
    veteran = enrollment!(caps, reference: staff, started_on: Date.new(2019, 12, 1))
    at = Time.zone.local(2020, 1, 15, 10)
    full = described_class.problems(input(performed_at: at, quantity: 999, participants: [ participant(veteran) ]),
                                    unit: caps, link: link, now: Time.current)
    expect(full).to eq(instrument: "raas_psi", problems: [])
    crisis = described_class.problems(input(sigtap_code: "0301080291", performed_at: at, participants: [ participant(veteran) ]),
                                      unit: caps, link: link, now: Time.current)
    expect(crisis).to eq(instrument: "raas_psi", problems: [])
  end

  describe ".recheck" do
    it "relê só instrumento, CBO gravado, quantidade e autorização; matrícula encerrada depois não pesa" do
      action = record_action!(caps, staff, participants: [ { enrollment_id: enrollment.id } ])
      enrollment.update_columns(closed_on: Date.current, destination: "01", closed_by_user_id: staff.id)
      expect(described_class.recheck(action)).to eq([])
    end

    it "o CBO gravado na ação é o que conta (não o vínculo de hoje)" do
      action = record_action!(caps, staff, participants: [ { enrollment_id: enrollment.id } ])
      allow(action).to receive(:cbo_code).and_return("515105")
      expect(described_class.recheck(action)).to eq([ { error: "cbo_incompatible", path: "sigtap_code" } ])
    end
  end
end
