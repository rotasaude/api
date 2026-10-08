# spec/config/ledi/consultation_mapping_spec.rb
require "rails_helper"

# ADR 0031 / spec §6 (Tarefa 1): o mapeamento da consulta para o LEDI 8.7.0 tem
# fonte em cada linha e bate com os IDLs vendorizados.
RSpec.describe Ledi::ConsultationMapping do
  def idl_fields(file, struct)
    text = Rails.root.join("vendor/ledi/8.7.0/idl", file).read
    body = text[/struct\s+#{struct}\s*\{(.*?)\n\}/m, 1] or raise "#{struct} não está em #{file}"
    body.scan(/^\s*\d+:\s*(?:required|optional)\s+[\w.<>]+\s+(\w+)/).flatten
  end

  it "é da versão ativa e toda entrada tem valor e fonte" do
    expect(described_class.data.fetch("ledi_version")).to eq(Ledi::Version::ACTIVE)
    described_class.data.fetch("entries").each do |key, entry|
      expect(entry.keys).to contain_exactly("value", "source"), key
      expect(entry["source"].to_s.strip).not_to be_empty, key
    end
    %w[care_types conducts cid10_cbos].each { |k| expect(described_class.data.dig(k, "source")).to be_present, k }
  end

  it "os campos usados existem nos IDLs" do
    expect(idl_fields("ras/ficha_atendimento_individual.thrift", "FichaAtendimentoIndividualChildThrift"))
      .to include("tipoAtendimento", "exame", "condutas", "problemasCondicoes", "medicoes", "cpfCidadao",
                  "stCidadaoNaoPossuiCpf", "dataHoraInicialAtendimento", "dataHoraFinalAtendimento")
    expect(idl_fields("ras/common.thrift", "ExameThrift")).to eq(%w[codigoExame solicitadoAvaliado])
    expect(idl_fields("ras/common.thrift", "ProblemaCondicaoThrift"))
      .to eq(%w[uuidProblema uuidEvolucaoProblema coSequencialEvolucao ciap cid10 situacao dataInicioProblema dataFimProblema isAvaliado])
  end

  it "tipos de atendimento da consulta: 1, 2, 5 e 6 (nunca 4, que é a escuta)" do
    expect(described_class.care_types.map { |t| t[:code] }).to eq([ 1, 2, 5, 6 ])
    expect(described_class.care_types).to all(include(:label))
    expect(described_class.care_type?(4)).to be(false)
    expect(described_class.care_type?("5")).to be(false) # só inteiro
    expect(described_class.care_type_label(2)).to eq("Consulta agendada")
  end

  it "condutas do dicionário, até 12" do
    expect(described_class.conducts.map { |c| c[:code] }).to eq([ 1, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 14 ])
    expect(described_class.conduct?(3)).to be(false)
    expect(described_class.conduct_label(9)).to eq("Alta do episódio")
    expect(described_class.max_conducts).to eq(12)
  end

  it "situação, exame e local" do
    expect([ described_class.situation("active"), described_class.situation("resolved") ]).to eq([ 0, 2 ])
    expect([ described_class.exam_requested, described_class.exam_group_prefix, described_class.max_exams ]).to eq([ "S", "02", 100 ])
    expect(described_class.local_de_atendimento).to eq(1)
    expect(described_class.value("tipo_dado_serializado.atendimento_individual")).to eq(Ledi::FichaTypes.code("atendimento_individual"))
  end

  it "CID-10 só para médicos (physicians_only; contrato §9)" do
    expect(described_class.data.dig("cid10_cbos", "rule")).to eq("physicians_only")
    %w[225125 225142 225170 225250 225350].each { |cbo| expect(described_class.cid10_allowed?(cbo)).to be(true), cbo }
    expect(described_class.data.dig("cid10_cbos", "prefixes")).to eq(%w[2251 2252 2253])
    expect(described_class.cid10_allowed?("225199")).to be(false) # prefixo médico fora da Tabela 3
    expect(described_class.cid10_allowed?("223505")).to be(false) # enfermeiro
    expect(described_class.cid10_allowed?("322205")).to be(false) # técnico
    unknown = described_class.data.merge("cid10_cbos" => { "rule" => "outra", "source" => "x" })
    allow(described_class).to receive(:data).and_return(unknown)
    expect { described_class.cid10_allowed?("225125") }.to raise_error(described_class::Missing)
  end

  it "chave inexistente levanta" do
    expect { described_class.value("nao.existe") }.to raise_error(described_class::Missing)
  end
end
