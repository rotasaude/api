require "rails_helper"

# ADR 0039 (spec §5.4–§5.5, §6; contrato §5): fecha por estabelecimento e
# competência com a crítica recalculada (cadastro do momento); BPA-I item a
# item, BPA-C agregado; cabeçalho com a competência de processamento e
# linha com a de realização; arquivo cifrado, só acréscimo; procedimentos
# ligados à versão; UBS nunca; nada a exportar não fecha.
RSpec.describe Billing::Close do
  include ActiveSupport::Testing::TimeHelpers

  before do
    travel_to(Time.zone.local(Time.zone.today.year, Time.zone.today.month, 15, 12, 0, 0))
    billing_city!
    billing_settings!
  end

  after { travel_back }

  let(:unit) { upa! }
  let(:doctor) { doctor!(unit) }
  let(:nurse) { nurse!(unit) }
  let(:clerk) { billing_clerk! }
  let(:patient) { billing_patient! }
  let(:today) { Time.zone.today }
  let(:competence) { today.strftime("%Y%m") }

  def period = BillingPeriod.find_by!(health_unit_id: unit.id, competence: competence)
  def lines(export) = export.bytes.split("\r\n")
  def age = format("%03d", Citizen.age_between(Date.iso8601(patient.birth_date), today))

  it "gera a versão 1: BPA-I item a item, BPA-C agregado, controle, cabeçalho e eventos" do
    i1 = recorded_procedure!(unit: unit, professional: doctor, patient: patient)
    i2 = recorded_procedure!(unit: unit, professional: doctor, patient: patient, cid10: "E119", character: "urgent")
    c1 = recorded_procedure!(unit: unit, professional: nurse, patient: patient, sigtap_code: "0301100012", cid10: nil, quantity: 2)
    c2 = recorded_procedure!(unit: unit, professional: nurse, patient: patient, sigtap_code: "0301100012", cid10: nil, quantity: 3)
    bad = recorded_procedure!(unit: unit, professional: doctor, patient: patient, cid10: nil)
    result = described_class.call(period: period, by: clerk)
    export = result.payload[:export]
    control = (301_100_012 + 5 + (301_060_029 + 1) * 2) % 1111 + 1111
    expect(export).to have_attributes(version: 1, cnes: unit.cnes, competence: competence, lines_bpa_i: 2, lines_bpa_c: 1, sheets: 2,
                                      control_field: control, sha256: Digest::SHA256.hexdigest(export.bytes), generated_by_user_id: clerk.id)
    header, c_line, *i_lines = lines(export)
    expect(header[0, 29]).to eq("01#BPA##{competence}000003000002#{control}")
    expect(header[29, 30]).to eq("SMS CURITIBA".ljust(30))
    expect(c_line).to eq("02#{unit.cnes}#{competence}223505001010301100012#{age}000005BPA")
    expect(i_lines.map { |l| l[49, 10] }).to eq(%w[0301060029 0301060029])
    expect(i_lines.map { |l| l[94, 2] }).to match_array(%w[01 02])
    expect(i_lines.map { |l| l[338, 11] }.uniq).to eq([ patient.cpf ])
    expect(i_lines.first[15, 15]).to eq(doctor.professional.cns)
    expect(i_lines.first[75, 6]).to eq("410690")
    expect([ i1, i2, c1, c2 ].map { |p| p.reload.billing_export_id }.uniq).to eq([ export.id ])
    expect(bad.reload.billing_export_id).to be_nil
    expect(period).to have_attributes(status: "closed", version: 1, closed_by_user_id: clerk.id)
    expect(DomainEvent.where(name: %w[billing_export.generated billing_period.closed]).pluck(:payload))
      .to contain_exactly({ "billing_export_id" => export.id, "billing_period_id" => period.id }, { "billing_period_id" => period.id, "version" => 1 })
  end

  it "atrasado no arquivo: linha com o mês da realização, cabeçalho com a competência fechada agora" do
    previous = (today << 1).strftime("%Y%m")
    BillingPeriod.create!(health_unit: unit, competence: previous, status: "closed", version: 1, closed_at: Time.current, closed_by_user: clerk)
    recorded_procedure!(unit: unit, professional: doctor, patient: patient, performed_on: today << 1)
    header, line = lines(described_class.call(period: period, by: clerk).payload[:export])
    expect(header[7, 6]).to eq(competence)
    expect(line[9, 6]).to eq(previous)
    expect(line[36, 8]).to eq((today << 1).strftime("%Y%m%d"))
  end

  it "cadastro corrigido basta: sem perfil nem vínculo na gravação, com perfil e vínculo no fechamento" do
    newcomer = staff_with("novato-#{SecureRandom.hex(3)}@cidade.gov.br", "health_professional")
    procedure = Billing::Record.call(patient: patient, establishment: Billing::Establishment.for_unit(unit), professional: newcomer, source: "manual",
                                     recorded_by: clerk, params: { "performed_on" => today.iso8601, "sigtap_code" => "0301060029",
                                                                   "quantity" => 1, "cid10" => "I10" }).payload[:procedure]
    expect(procedure.blocking_reasons).to eq(%w[missing_professional_cbo missing_professional_cns])
    expect(Billing::Pending.call(period).sole).to include(procedure_id: procedure.id, fix: "professional")
    link_professional!(newcomer, unit, cbo: "225125")
    export = described_class.call(period: period, by: clerk).payload[:export]
    expect(procedure.reload).to have_attributes(billable: true, blocking_reasons: [], cbo_code: "225125", billing_export_id: export.id)
    expect(lines(export).last[15, 15]).to eq(newcomer.reload.professional.cns)
  end

  it "nada a exportar: 422 e a competência segue aberta, com a crítica atualizada" do
    bad = recorded_procedure!(unit: unit, professional: doctor, patient: patient, cid10: nil)
    expect(described_class.call(period: period, by: clerk).reason).to eq(:nothing_to_export)
    expect(period).to have_attributes(status: "open", version: 0)
    expect(BillingExport.count).to eq(0)
    expect(bad.reload.blocking_reasons).to eq(%w[cid_required])
  end

  it "sem configuração, fechada ou virada UBS: recusa sem arquivo" do
    recorded_procedure!(unit: unit, professional: doctor, patient: patient)
    BillingSetting.delete_all
    expect(described_class.call(period: period, by: clerk).reason).to eq(:settings_missing)
    billing_settings!
    expect(described_class.call(period: period, by: clerk)).to be_ok
    expect(described_class.call(period: period, by: clerk).reason).to eq(:invalid_transition)
    other = upa!
    recorded_procedure!(unit: other, professional: doctor!(other), patient: patient)
    other.update!(kind: "ubs")
    result = described_class.call(period: BillingPeriod.find_by!(health_unit_id: other.id), by: clerk)
    expect(result.reason).to eq(:establishment_is_aps)
    expect(BillingExport.joins(:billing_period).where(billing_periods: { health_unit_id: other.id })).to be_empty
  end

  it "D-U1: paciente sem raça/cor ou endereço fica fora do arquivo até o cadastro ser completado" do
    bare = billing_patient!(demographics: false)
    pending = recorded_procedure!(unit: unit, professional: doctor, patient: bare)
    done = recorded_procedure!(unit: unit, professional: doctor, patient: patient)
    expect(Billing::Pending.call(period).map { |i| [ i[:procedure_id], i[:reasons], i[:fix] ] })
      .to eq([ [ pending.id, %w[missing_race_color missing_address], "patient" ] ])
    export = described_class.call(period: period, by: clerk).payload[:export]
    expect(pending.reload).to have_attributes(billable: false, blocking_reasons: %w[missing_race_color missing_address], billing_export_id: nil)
    expect(done.reload.billing_export_id).to eq(export.id)
  end

  it "a configuração entra no cabeçalho, com a sigla" do
    BillingSetting.current.update!(origin_acronym: "SMS", destination_body: "Secretaria Estadual", management: "E")
    recorded_procedure!(unit: unit, professional: doctor, patient: patient)
    header = lines(described_class.call(period: period, by: clerk).payload[:export]).first
    expect(header[59, 6]).to eq("SMS   ")
    expect(header[65, 14]).to eq("11222333000181")
    expect(header[79, 41]).to eq("SECRETARIA ESTADUAL".ljust(40) + "E")
    expect(header[120, 10]).to eq("ROTASAUDE ")
  end

  # §13 E4: endereço sem número entra no BPA-I com SN (posições 243–247).
  it "paciente sem número no endereço: BPA-I com SN" do
    patient.update!(address_number: nil)
    recorded_procedure!(unit: unit, professional: doctor, patient: patient)
    line = lines(described_class.call(period: period, by: clerk).payload[:export]).last
    expect(line[242, 5]).to eq("SN   ")
  end

  # Fluxo do faturista (D-U1): a pendência de cadastro do paciente se resolve
  # com Patients::Demographics (o mesmo do PATCH /billing/patients/:id/demographics)
  # e o fechamento seguinte leva raça/cor e endereço às posições do layout.
  it "fim a fim: pendência do paciente, faturista corrige o cadastro, fechamento inclui no BPA-I" do
    bare = billing_patient!(demographics: false)
    procedure = recorded_procedure!(unit: unit, professional: doctor, patient: bare)
    expect(Billing::Pending.call(period).sole).to include(procedure_id: procedure.id, reasons: %w[missing_race_color missing_address], fix: "patient")
    values = Patients::Demographics.parse("race_color" => "01", "address_zip" => "80.420-000", "address_street" => "Rua Sete de Setembro",
                                          "address_number" => "", "address_district" => "Batel").payload[:values]
    expect(Patient.transaction { Patients::Demographics.save!(bare.lock!, values) }).to be_ok
    expect(Billing::Pending.call(period)).to eq([])
    export = described_class.call(period: period, by: clerk).payload[:export]
    expect(procedure.reload).to have_attributes(billable: true, blocking_reasons: [], billing_export_id: export.id)
    line = lines(export).last
    expect(line[150, 2]).to eq("01")                                       # 151–152 raça/cor
    expect(line[191, 8]).to eq("80420000")                                 # 192–199 CEP
    expect(line[202, 30]).to eq("RUA SETE DE SETEMBRO".ljust(30))          # 203–232 logradouro
    expect(line[242, 5]).to eq("SN   ")                                    # 243–247 número
    expect(line[247, 30]).to eq("BATEL".ljust(30))                         # 248–277 bairro
    expect(line[338, 11]).to eq(bare.cpf)
  end
end
