require "rails_helper"
require "csv"

# Módulo 26a, Task 11 (ADR 0044; contrato §8, §13 G8, G10, G12; overlay): o CSV
# para digitar no sistema do estado. Cabeçalho fixo (com ciap2), BOM, `;`,
# `\r\n`, CNS só os 4 últimos dígitos, sem CPF, célula de fórmula protegida.
RSpec.describe CareRegulation::StateCsv do
  include ActiveSupport::Testing::TimeHelpers

  let(:now) { Time.zone.local(2026, 10, 28, 10, 0) }

  before do
    travel_to now
    regulation_city!
  end

  let(:expected_header) do
    %w[pedido_id data_pedido situacao tipo codigo_alvo alvo cor prazo cid10 ciap2 justificativa paciente cns_final nascimento sexo
       unidade_solicitante unidade_cnes solicitante solicitante_cbo sistema_externo numero_externo]
  end

  def parse(csv) = CSV.parse(csv.delete_prefix("﻿"), col_sep: ";", headers: true)

  def external!(cns_tail: "1234", cnes: "2345678", **over)
    patient, citizen = regulation_patient!(exam_seq!)
    patient.update!(cns: "7000000000#{cns_tail.rjust(5, '0')}")
    unit = create_unit("UBS Estado #{SecureRandom.hex(2)}").tap { |u| u.update!(cnes: cnes) }
    request = regulation_request!(citizen: citizen, unit: unit, **over)
    marked = CareRegulation::MarkExternal.call(request: request, system: "sisreg", number: "55-1234", version: request.version,
                                               by: care_regulator!)
    raise "marcação recusada: #{marked.reason}" if marked.failure?

    [ request.reload, citizen, patient ]
  end

  it "cabeçalho fixo, BOM no início, `;` e `\\r\\n`" do
    external!
    built = described_class.build(status: "external")
    expect(built.fetch(:csv)).to start_with("﻿pedido_id;data_pedido;situacao;")
    expect(built.fetch(:csv)).to include("\r\n")
    expect(built.fetch(:csv).lines.first.chomp.delete_prefix("﻿").split(";")).to eq(expected_header)
    expect(described_class::HEADER).to eq(expected_header)
    expect(built.fetch(:csv).encoding).to eq(Encoding::UTF_8)
  end

  it "uma linha por pedido da situação pedida (padrão external), ordem requested_at e id, com os ids" do
    first, = external!
    travel_to now + 1.day
    second, = external!(cns_tail: "5678", cnes: "3456789")
    regulation_request! # pending: fora do padrão
    built = described_class.build
    expect(built.fetch(:ids)).to eq([ first.id, second.id ])
    expect(parse(built.fetch(:csv)).map { |r| r["pedido_id"] }).to eq([ first.id, second.id ])
    expect(described_class.build(status: "pending").fetch(:ids).size).to eq(1)
  end

  it "campos: datas dd/mm/aaaa, CNS só os 4 últimos, solicitante, unidade e sistema/número do estado" do
    request, = external!(suggested_color: "red")
    row = parse(described_class.build.fetch(:csv)).first
    expect(row.to_h).to include(
      "pedido_id" => request.id, "data_pedido" => "28/10/2026", "situacao" => "external", "tipo" => "specialty",
      "codigo_alvo" => "225120", "alvo" => request.target_name, "cor" => "red", "prazo" => "04/11/2026", "cid10" => "I10", "ciap2" => "",
      "justificativa" => request.justification, "paciente" => request.patient.display_name, "cns_final" => "1234",
      "sexo" => "F", "unidade_solicitante" => request.requester_unit.name, "unidade_cnes" => "2345678",
      "solicitante_cbo" => "225125", "sistema_externo" => "sisreg", "numero_externo" => "55-1234"
    )
    expect(row["nascimento"]).to match(%r{\A\d{2}/\d{2}/\d{4}\z})
    expect(row["solicitante"]).to eq(Screenings::Json.staff_name(request.requester_user))
  end

  it "nenhuma célula com o CPF nem o CNS inteiro" do
    _request, citizen, patient = external!
    csv = described_class.build.fetch(:csv)
    expect(citizen.cpf).to be_present
    expect(csv).not_to include(citizen.cpf)
    expect(csv).not_to include(citizen.cpf.gsub(/\D/, ""))
    expect(csv).not_to include(patient.cns)
    expect(csv).not_to include("70000000000")
  end

  it "pedido de enfermeira só com ciap2: cid10 vazio e ciap2 K86 (overlay G10)" do
    request, = external!
    request.update!(cid10: nil, ciap2: "K86")
    row = parse(described_class.build.fetch(:csv)).first
    expect(row.to_h).to include("cid10" => "", "ciap2" => "K86")
  end

  it "célula que começa com `=` sai protegida pelo apóstrofo" do
    external!(justification: "=1+1 hipertensão resistente a três fármacos")
    row = parse(described_class.build.fetch(:csv)).first
    expect(row["justificativa"]).to eq("'=1+1 hipertensão resistente a três fármacos")
  end

  it "sem pedidos → só o cabeçalho e nenhum id" do
    built = described_class.build
    expect(built.fetch(:ids)).to eq([])
    expect(built.fetch(:csv).delete_prefix("﻿").lines.size).to eq(1)
  end
end
