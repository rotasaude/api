require "rails_helper"

# Módulo 28 (ADR 0046; F-28.2; contrato §16 O19): a consulta odontológica
# finalizada vira a FAO (tipo 5) pelo mesmo caminho da consulta da APS
# (Ledi::ConsultationFicha). INE: a eSB do dentista na unidade, antes da eSF;
# Review Focus 2: no CEO, sem equipe, a ficha sai com INE nulo — nunca "não
# gerada" professional_without_team. O registro inicial não gera ficha; adendo
# só com achado não regera; adendo com problema avaliado regrava.
RSpec.describe "Ledi::ConsultationFicha — FAO" do
  let(:city) { ledi_ready!(dental_city!, pec_url: "https://pec.a.test", record_mode: "record", ibge_code: "4106902") }
  let(:unit) { create_unit }
  let(:dentist) { dentist!(unit) }
  let(:fichas) { Ledi::ConsultationFicha }

  before do
    Current.city = city
    allow(Ledi::DeliverJob).to receive(:perform_later)
  end
  after { Current.reset }

  def ficha_of(entry)
    Ledi::Version.deserialize(Ledi::FichaTypes.klass(entry.ficha_type), Ledi::Transport.read(entry.bytes).dadoSerializado)
  end

  def child_of(entry) = ficha_of(entry).atendimentosOdontologicos.sole

  # O dentista na eSF (desde 30 dias) e na eSB da mesma UBS (desde 10 dias).
  def oral_health_team!(unit, *users)
    esf = exportable_unit!(unit, *users)
    esb = HealthTeam.create!(health_unit: unit, ine: "0001234571", kind: DentalCare::Catalog::ORAL_HEALTH_TEAM_KIND,
                             name: "eSB Jardim das Flores", associated_team: esf)
    users.each do |user|
      HealthTeamMember.create!(professional: user.professional, health_team: esb, cbo_code: user.professional.links.active.first.cbo_code,
                               started_on: Time.zone.today - 10)
    end
    esb
  end

  def addendum!(consultation, changes) =
    Consultations::AddAddendum.call(consultation: consultation, by: consultation.author_user, reason: "correção estruturada",
                                    text: "ajuste", changes: changes)

  it "dentista da eSB (também na eSF) na UBS: a FAO entra na fila com o INE da eSB" do
    oral_health_team!(unit, dentist)
    expect(Ledi::ScreeningFicha.team_ine(dentist.professional, unit)).to eq("0000123456")
    consultation = finalized_dental!(unit: unit, by: dentist, citizen: verified_citizen!(1))
    expect(fichas.generate(consultation)).to eq(:enqueued)
    entry = LediOutboxEntry.sole
    expect(entry).to have_attributes(source_type: "Consultation", source_id: consultation.id, ficha_type: "atendimento_odontologico")
    expect(Ledi::Transport.read(entry.bytes).tipoDadoSerializado).to eq(5)
    lotacao = ficha_of(entry).headerTransport.lotacaoFormPrincipal
    expect([ lotacao.ine, lotacao.cnes, lotacao.cboCodigo_2002 ]).to eq([ "0001234571", unit.reload.cnes, "223208" ])
    child = child_of(entry)
    expect(child.procedimentosRealizados.map { |p| [ p.coMsProcedimento, p.quantidade ] }).to eq([ [ "0307010031", 1 ] ])
    expect([ child.tipoAtendimento, child.tiposConsultaOdonto, child.tiposVigilanciaSaudeBucal, child.tiposEncamOdonto, child.gestante ])
      .to eq([ 2, [ 1 ], [ 99 ], [ 16 ], false ])
    expect(child.problemasCondicoes.map(&:ciap)).to eq([ "D82" ])
    expect(fichas.generate(consultation)).to eq(:exists)
  end

  it "na finalização, o job da ficha gera a FAO (não mais :skipped)" do
    oral_health_team!(unit, dentist)
    consultation = finalized_dental!(unit: unit, by: dentist, citizen: verified_citizen!(1))
    Ledi::ConsultationFichaJob.perform_now(city_slug: city.slug, consultation_id: consultation.id)
    expect(LediOutboxEntry.sole.ficha_type).to eq("atendimento_odontologico")
  end

  # Review Focus 2.
  it "endodontista do CEO sem equipe: a FAO entra na fila com INE nulo e o CNES do CEO" do
    ceo = ceo_unit!
    ceo.update!(cnes: "7654321")
    endodontist = dentist!(ceo, cbo: "223212")
    consultation = finalized_dental!(unit: ceo, by: endodontist, citizen: verified_citizen!(1))
    expect(fichas.generate(consultation)).to eq(:enqueued)
    expect(LediGenerationFailure.count).to eq(0)
    entry = LediOutboxEntry.sole
    lotacao = ficha_of(entry).headerTransport.lotacaoFormPrincipal
    expect([ lotacao.ine, lotacao.cnes, lotacao.cboCodigo_2002 ]).to eq([ nil, "7654321", "223212" ])
    expect(child_of(entry).localAtendimento).to eq(1)
  end

  it "dentista sem equipe fora do CEO: 'não gerada' professional_without_team; CEO sem CNES: só unit_without_cnes" do
    unit.update!(cnes: "1234567")
    expect(fichas.generate(finalized_dental!(unit: unit, by: dentist, citizen: verified_citizen!(1)))).to eq(:failed)
    expect(LediGenerationFailure.sole.reason_codes).to eq(%w[professional_without_team])

    ceo = ceo_unit!
    expect(fichas.generate(finalized_dental!(unit: ceo, by: dentist!(ceo, cbo: "223212"), citizen: verified_citizen!(2)))).to eq(:failed)
    expect(LediGenerationFailure.order(:created_at).last.reason_codes).to eq(%w[unit_without_cnes])
  end

  # Cinto: a finalização já recusa (O32, Desvio 6); a ficha nunca trunca.
  it "mais de 20 SIGTAP ou soma acima do limite do local: 'não gerada', nada na fila" do
    oral_health_team!(unit, dentist)
    consultation = finalized_dental!(unit: unit, by: dentist, citizen: verified_citizen!(1))
    rows = (1..21).map { |n| [ format("03070100%02d", n), 1 ] } + [ [ "0101020074", 1 ], [ "0101020074", 1 ] ]
    allow(consultation).to receive(:dental_procedures).and_return(double(pluck: rows))
    expect(fichas.generate(consultation)).to eq(:failed)
    expect(LediGenerationFailure.sole.reason_codes).to eq(%w[too_many_procedure_codes quantity_exceeds_location_limit])
    expect(LediOutboxEntry.count).to eq(0)
  end

  it "unidade sem CNES: 'não gerada' unit_without_cnes" do
    oral_health_team!(unit, dentist)
    unit.update!(cnes: nil)
    consultation = finalized_dental!(unit: unit, by: dentist, citizen: verified_citizen!(1))
    expect(fichas.generate(consultation)).to eq(:failed)
    expect(LediGenerationFailure.sole.reason_codes).to eq(%w[unit_without_cnes])
    expect(LediOutboxEntry.count).to eq(0)
  end

  it "registro inicial: nenhuma ficha nem falha" do
    oral_health_team!(unit, dentist)
    consultation = dental_consultation!(unit: unit, by: dentist, citizen: verified_citizen!(1), baseline: true)
    Consultations::SaveDraft.call(consultation: consultation, by: dentist,
                                  params: { "dental" => { "findings" => [ { "tooth" => 16, "situation" => "caries" } ] } })
    finalized = Consultations::Finalize.call(consultation: consultation.reload, outcome_params: { "outcome" => "discharged" }, by: dentist)
    expect(finalized).to be_ok
    expect(fichas.generate(consultation.reload)).to eq(:skipped)
    expect([ LediOutboxEntry.count, LediGenerationFailure.count ]).to eq([ 0, 0 ])
  end

  it "adendo só com achado: nenhuma regravação; com problema avaliado: regrava a pendente com o mesmo uuid" do
    oral_health_team!(unit, dentist)
    consultation = finalized_dental!(unit: unit, by: dentist, citizen: verified_citizen!(1))
    fichas.generate(consultation)
    entry = LediOutboxEntry.sole
    allow(Ledi::ConsultationFichaJob).to receive(:enqueue_for).and_call_original

    findings = addendum!(consultation, "dental" => { "findings" => [ { "tooth" => 16, "situation" => "caries" } ] })
    expect(findings).to be_ok
    expect(findings.payload[:ficha_changed]).to be(false)
    expect(Ledi::ConsultationFichaJob).not_to have_received(:enqueue_for)

    resolved = addendum!(consultation, "evaluated_problems" => [ { "problem_id" => PatientProblem.sole.id, "action" => "resolve" } ])
    expect(resolved.payload[:ficha_changed]).to be(true)
    expect(Ledi::ConsultationFichaJob).to have_received(:enqueue_for).with(consultation, reason: "addendum")
    expect(fichas.refresh!(consultation.reload)).to eq(:rewritten)
    expect(entry.reload.uuid).to eq(entry.uuid)
    expect(child_of(entry).problemasCondicoes.sole.situacao).to eq(2)
  end

  # Inalcançável hoje (consulta exige par validado, que tem CPF): stub do paciente, como no 24a.
  it "paciente sem CPF: CNS com a justificativa" do
    oral_health_team!(unit, dentist)
    no_cpf = registry_no_cpf_patient!(cns: valid_cns(28))
    consultation = finalized_dental!(unit: unit, by: dentist, citizen: verified_citizen!(1))
    allow(consultation).to receive(:patient).and_return(no_cpf)
    expect(fichas.generate(consultation)).to eq(:enqueued)
    child = child_of(LediOutboxEntry.sole)
    expect([ child.cpfCidadao, child.cnsCidadao, child.stCidadaoNaoPossuiCpf, child.justificativaCidadaoNaoPossuiCpf ])
      .to eq([ nil, no_cpf.cns, true, 3 ])
  end
end
