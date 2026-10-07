require "rails_helper"

# ADR 0030 (spec §5): ficha por CBO, só com a exportação utilizável; sem
# identificação completa, "não gerada" com motivo; uma ficha por escuta.
# Decisão D10 do product owner (2026-10-07, substitui spec §5): técnico sem
# aferição ainda gera a Ficha de Procedimentos, só com a marca de escuta.
RSpec.describe Ledi::ScreeningFicha do
  let(:city) { ledi_ready!(register_test_city!, pec_url: "https://pec.a.test", record_mode: "record", ibge_code: "4106902") }
  let(:unit) { create_unit }
  let(:nurse) { screener!(unit) }

  around { |ex| CityConnection.with(city) { ex.run } }
  before do
    ciap2_release!
    allow(Ledi::DeliverJob).to receive(:perform_later)
  end

  def screening_for(citizen, by: nurse, destination: "oriented", **revision)
    attendance = walk_in_attendance!(unit, citizen: citizen)
    started = Screenings::Start.call(attendance: attendance, by: by).payload[:screening]
    params = destination == "oriented" ? { "orientation_note" => "repouso" } : {}
    Screenings::Complete.call(screening: started, revision_params: revision_params(**revision), destination: destination,
                              destination_params: params, by: by)
    started.reload
  end

  def procedures_child(entry)
    transport = Ledi::Transport.read(entry.bytes)
    master = Ledi::Version.deserialize(Br::Gov::Saude::Esusab::Ras::Atendprocedimentos::FichaProcedimentoMasterThrift,
                                       transport.dadoSerializado)
    master.atendProcedimentos.sole
  end

  it "nível superior: Atendimento Individual na fila, uma vez só; transporte tipo 4" do
    exportable_unit!(unit, nurse)
    screening = screening_for(screening_citizen!(1))
    expect(described_class.generate(screening, city: city)).to eq(:enqueued)
    entry = LediOutboxEntry.sole
    expect(entry).to have_attributes(source_type: "Screening", source_id: screening.id, ficha_type: "atendimento_individual",
                                     status: "pending")
    expect(Ledi::Transport.read(entry.bytes).tipoDadoSerializado).to eq(4)
    expect(described_class.generate(screening, city: city)).to eq(:exists)
    expect(LediOutboxEntry.count).to eq(1)
  end

  it "técnico com aferição: Procedimentos com SIGTAP; sem aferição (D10): Procedimentos só com a marca, sem 'não gerada'" do
    tech = screener!(unit, cbo: "322205")
    exportable_unit!(unit, tech)
    with_bp = screening_for(screening_citizen!(1), by: tech)
    expect(described_class.generate(with_bp, city: city)).to eq(:enqueued)
    measured = LediOutboxEntry.sole
    expect(measured.ficha_type).to eq("procedimento")
    expect(procedures_child(measured).procedimentos).to be_present

    bare = screening_for(screening_citizen!(2), by: tech, vitals: { "spo2" => 97 })
    expect(described_class.generate(bare, city: city)).to eq(:enqueued)
    flag_only = LediOutboxEntry.find_by!(source_type: "Screening", source_id: bare.id)
    expect(flag_only.ficha_type).to eq("procedimento")
    child = procedures_child(flag_only)
    expect(child.statusEscutaInicialOrientacao).to be(true)
    expect(child.procedimentos).to be_nil
    expect(LediOutboxEntry.count).to eq(2)
    expect(LediGenerationFailure.count).to eq(0)
  end

  it "sem identificação: 'não gerada' com os motivos, evento só com ids; corrigido, gera e resolve" do
    citizen = Citizen.create!(cpf: "52998224725", phone: "+5541998765432")
    screening = screening_for(citizen)
    expect(described_class.generate(screening, city: city)).to eq(:failed)
    failure = LediGenerationFailure.sole
    expect(failure.reason_codes).to eq(%w[unit_without_cnes professional_without_team citizen_without_birth_date citizen_without_sex])
    expect(DomainEvent.where(name: "ledi.generation_failed").sole.payload)
      .to eq("failure_id" => failure.id, "source_type" => "Screening", "source_id" => screening.id)
    expect(described_class.generate(screening, city: city)).to eq(:failed)
    expect(DomainEvent.where(name: "ledi.generation_failed").count).to eq(1)

    exportable_unit!(unit, nurse)
    citizen.update!(birth_date: "1980-05-10", sex: "female", profile_source: "declared")
    expect(described_class.generate(screening.reload, city: city)).to eq(:enqueued) # como o job: relido
    expect(LediGenerationFailure.unresolved.count).to eq(0)
    expect(failure.reload.resolved_at).to be_present
  end

  it "CIAP-2 que não existe na release gravada → unknown_ciap2" do
    exportable_unit!(unit, nurse)
    screening = screening_for(screening_citizen!(1))
    # A terminologia da plataforma é imutável (trigger); simula a release gravada sem o código.
    allow(Ciap2Code).to receive(:exists?).and_return(false)
    expect(described_class.generate(screening, city: city)).to eq(:failed)
    expect(LediGenerationFailure.sole.reason_codes).to eq(%w[unknown_ciap2])
  end

  it "exportação desligada, record_mode off ou credencial recusada: nada nasce (nem 'não gerada')" do
    exportable_unit!(unit, nurse)
    screening = screening_for(screening_citizen!(1))
    ledi_off!(city)
    expect(described_class.generate(screening, city: city)).to eq(:unusable)
    ledi_ready!(city, pec_url: "https://pec.a.test", record_mode: "off")
    expect(described_class.generate(screening, city: city)).to eq(:unusable)
    ledi_ready!(city, pec_url: "https://pec.a.test", record_mode: "record")
    IntegrationCredential.find_by!(kind: "ledi").update!(last_check_status: "unauthorized")
    expect(described_class.generate(screening, city: city)).to eq(:unusable)
    expect([ LediOutboxEntry.count, LediGenerationFailure.count ]).to eq([ 0, 0 ])
  end

  it "escuta em curso ou abandonada não gera" do
    attendance = walk_in_attendance!(unit, citizen: screening_citizen!(1))
    started = Screenings::Start.call(attendance: attendance, by: nurse).payload[:screening]
    expect(described_class.generate(started, city: city)).to eq(:skipped)
    Screenings::Abandon.call(screening: started, by: nurse)
    expect(described_class.generate(started.reload, city: city)).to eq(:skipped)
    expect([ LediOutboxEntry.count, LediGenerationFailure.count ]).to eq([ 0, 0 ])
  end
end
