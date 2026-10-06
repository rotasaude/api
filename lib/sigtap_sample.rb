# lib/sigtap_sample.rb
require "fileutils"

# Recorte da Tabela Unificada SIGTAP (ADR 0028; spec 2026-10-05 §4, §9, §10):
# códigos reais de procedimentos da APS, no formato do ZIP oficial — cada
# arquivo de largura fixa com o seu `<arquivo>_layout.txt` (Coluna, Tamanho,
# Inicio, Fim, Tipo). Idade em meses (9999 = sem limite). Os atributos do
# recorte (CBOs, CIDs, idades) servem para teste e para a semente de dev; a
# verdade é a competência importada do DATASUS.
module SigtapSample
  LAYOUTS = {
    "tb_procedimento" => [ [ "CO_PROCEDIMENTO", 10, "VARCHAR2" ], [ "NO_PROCEDIMENTO", 250, "VARCHAR2" ],
                           [ "TP_COMPLEXIDADE", 1, "VARCHAR2" ], [ "TP_SEXO", 1, "VARCHAR2" ],
                           [ "QT_MAXIMA_EXECUCAO", 4, "NUMBER" ], [ "QT_DIAS_PERMANENCIA", 4, "NUMBER" ],
                           [ "QT_PONTOS", 4, "NUMBER" ], [ "VL_IDADE_MINIMA", 4, "NUMBER" ],
                           [ "VL_IDADE_MAXIMA", 4, "NUMBER" ], [ "DT_COMPETENCIA", 6, "VARCHAR2" ] ],
    "rl_procedimento_ocupacao" => [ [ "CO_PROCEDIMENTO", 10, "VARCHAR2" ], [ "CO_OCUPACAO", 6, "VARCHAR2" ],
                                    [ "DT_COMPETENCIA", 6, "VARCHAR2" ] ],
    "rl_procedimento_cid" => [ [ "CO_PROCEDIMENTO", 10, "VARCHAR2" ], [ "CO_CID", 4, "VARCHAR2" ],
                               [ "ST_PRINCIPAL", 1, "VARCHAR2" ], [ "DT_COMPETENCIA", 6, "VARCHAR2" ] ],
    "rl_procedimento_registro" => [ [ "CO_PROCEDIMENTO", 10, "VARCHAR2" ], [ "CO_REGISTRO", 2, "VARCHAR2" ],
                                    [ "DT_COMPETENCIA", 6, "VARCHAR2" ] ],
    "tb_registro" => [ [ "CO_REGISTRO", 2, "VARCHAR2" ], [ "NO_REGISTRO", 50, "VARCHAR2" ],
                       [ "DT_COMPETENCIA", 6, "VARCHAR2" ] ]
  }.freeze

  # código, nome, complexidade, sexo, idade mínima, idade máxima (meses)
  PROCEDURES = [
    [ "0301010064", "CONSULTA MEDICA EM ATENCAO PRIMARIA", "1", "I", 0, 9999 ],
    [ "0301010030", "CONSULTA DE PROFISSIONAIS DE NIVEL SUPERIOR NA ATENCAO PRIMARIA (EXCETO MEDICO)", "1", "I", 0, 9999 ],
    [ "0201020033", "COLETA DE MATERIAL P/ EXAME CITOPATOLOGICO DE COLO UTERINO", "1", "F", 120, 1560 ],
    [ "0301100039", "AFERICAO DE PRESSAO ARTERIAL", "1", "I", 0, 9999 ],
    [ "0301040079", "ESCUTA INICIAL / ORIENTACAO (ACOLHIMENTO A DEMANDA ESPONTANEA)", "1", "I", 0, 9999 ]
  ].freeze

  CBOS = {
    "0301010064" => %w[225125 225142 225130 225170],
    "0301010030" => %w[223505 251510],
    "0201020033" => %w[223505 225125],
    "0301100039" => %w[223505 322205 225125],
    "0301040079" => %w[223505 322205 225125]
  }.freeze

  CIDS = { "0201020033" => [ %w[Z014 S] ] }.freeze

  INSTRUMENTS = {
    "0301010064" => %w[02], "0301010030" => %w[02], "0201020033" => %w[01 02], "0301100039" => %w[01],
    "0301040079" => %w[01]
  }.freeze

  REGISTRIES = { "01" => "BPA (CONSOLIDADO)", "02" => "BPA (INDIVIDUALIZADO)" }.freeze

  module_function

  def write_to(dir, competence:)
    dir = Pathname(dir)
    FileUtils.mkdir_p(dir)
    LAYOUTS.each do |file, columns|
      dir.join("#{file}_layout.txt").write(layout_lines(columns).join("\r\n") + "\r\n")
      data = rows_for(file, competence).map { |values| fixed(columns, values) }
      dir.join("#{file}.txt").binwrite((data.join("\r\n") + "\r\n").encode("ISO-8859-1"))
    end
    dir
  end

  def layout_lines(columns)
    start = 1
    [ "Coluna,Tamanho,Inicio,Fim,Tipo" ] + columns.map do |name, size, type|
      line = "#{name},#{size},#{start},#{start + size - 1},#{type}"
      start += size
      line
    end
  end

  def fixed(columns, values)
    columns.zip(values).map { |(_, size, type), v| type == "NUMBER" ? v.to_s.rjust(size, "0") : v.to_s.ljust(size) }.join
  end

  def rows_for(file, competence)
    case file
    when "tb_procedimento"
      PROCEDURES.map { |code, name, cx, sex, min, max| [ code, name, cx, sex, 9999, 0, 0, min, max, competence ] }
    when "rl_procedimento_ocupacao" then CBOS.flat_map { |code, cbos| cbos.map { |cbo| [ code, cbo, competence ] } }
    when "rl_procedimento_cid" then CIDS.flat_map { |code, cids| cids.map { |cid, principal| [ code, cid, principal, competence ] } }
    when "rl_procedimento_registro" then INSTRUMENTS.flat_map { |code, regs| regs.map { |reg| [ code, reg, competence ] } }
    when "tb_registro" then REGISTRIES.map { |code, name| [ code, name, competence ] }
    end
  end
end
