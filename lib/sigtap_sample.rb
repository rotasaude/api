# lib/sigtap_sample.rb
require "fileutils"

# Recorte da Tabela Unificada SIGTAP (ADR 0028; spec 2026-10-05 §4, §9, §10):
# códigos reais de procedimentos da APS, no formato do ZIP oficial — cada
# arquivo de largura fixa com o seu `<arquivo>_layout.txt` (Coluna, Tamanho,
# Inicio, Fim, Tipo). Idade em meses (9999 = sem limite). Os atributos do
# recorte (CBOs, CIDs, idades) servem para teste e para a semente de dev; a
# verdade é a competência importada do DATASUS.
# Módulo 22: códigos e atributos de faturamento de dev (instrumento, CBO, CID) —
# a verdade é a competência importada do DATASUS.
module SigtapSample
  LAYOUTS = {
    "tb_procedimento" => [ [ "CO_PROCEDIMENTO", 10, "VARCHAR2" ], [ "NO_PROCEDIMENTO", 250, "VARCHAR2" ],
                           [ "TP_COMPLEXIDADE", 1, "VARCHAR2" ], [ "TP_SEXO", 1, "VARCHAR2" ],
                           [ "QT_MAXIMA_EXECUCAO", 4, "NUMBER" ], [ "QT_DIAS_PERMANENCIA", 4, "NUMBER" ],
                           [ "QT_PONTOS", 4, "NUMBER" ], [ "VL_IDADE_MINIMA", 4, "NUMBER" ],
                           [ "VL_IDADE_MAXIMA", 4, "NUMBER" ], [ "VL_SH", 12, "NUMBER" ], [ "VL_SA", 12, "NUMBER" ],
                           [ "VL_SP", 12, "NUMBER" ], [ "DT_COMPETENCIA", 6, "VARCHAR2" ] ],
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
    [ "0301040079", "ESCUTA INICIAL / ORIENTACAO (ACOLHIMENTO A DEMANDA ESPONTANEA)", "1", "I", 0, 9999 ],
    [ "0202020380", "HEMOGRAMA COMPLETO", "2", "I", 0, 9999 ],
    [ "0202010503", "DOSAGEM DE HEMOGLOBINA GLICOSILADA", "2", "I", 0, 9999 ],
    [ "0202030300", "PESQUISA DE ANTICORPOS ANTI-HIV-1 + HIV-2 (ELISA)", "2", "I", 0, 9999 ],
    [ "0203020030", "EXAME ANATOMO-PATOLOGICO PARA CONGELAMENTO / PARAFINA POR PECA CIRURGICA OU POR BIOPSIA (EXCETO COLO UTERINO E MAMA)", "2", "I", 0, 9999 ],
    [ "0202010473", "DOSAGEM DE GLICOSE", "2", "I", 0, 9999 ],
    [ "0202010317", "DOSAGEM DE CREATININA", "2", "I", 0, 9999 ],
    [ "0202010295", "DOSAGEM DE COLESTEROL TOTAL", "2", "I", 0, 9999 ],
    [ "0202010279", "DOSAGEM DE COLESTEROL HDL", "2", "I", 0, 9999 ],
    [ "0202010287", "DOSAGEM DE COLESTEROL LDL", "2", "I", 0, 9999 ],
    [ "0202010678", "DOSAGEM DE TRIGLICERIDEOS", "2", "I", 0, 9999 ],
    [ "0202010694", "DOSAGEM DE UREIA", "2", "I", 0, 9999 ],
    [ "0202010643", "DOSAGEM DE TRANSAMINASE GLUTAMICO-OXALACETICA (TGO)", "2", "I", 0, 9999 ],
    [ "0202010651", "DOSAGEM DE TRANSAMINASE GLUTAMICO-PIRUVICA (TGP)", "2", "I", 0, 9999 ],
    [ "0202060250", "DOSAGEM DE HORMONIO TIREOESTIMULANTE (TSH)", "2", "I", 0, 9999 ],
    [ "0202060381", "DOSAGEM DE TIROXINA LIVRE (T4 LIVRE)", "2", "I", 0, 9999 ],
    [ "0202060217", "DOSAGEM DE GONADOTROFINA CORIONICA HUMANA (HCG, BETA HCG)", "2", "I", 0, 9999 ],
    [ "0202050017", "ANALISE DE CARACTERES FISICOS, ELEMENTOS E SEDIMENTO DA URINA", "2", "I", 0, 9999 ],
    [ "0202040127", "PESQUISA DE OVOS E CISTOS DE PARASITAS", "2", "I", 0, 9999 ],
    # Módulo 22 (ADR 0039): procedimentos da atenção especializada da UPA.
    [ "0301060029", "ATENDIMENTO DE URGENCIA C/ OBSERVACAO ATE 24 HORAS EM ATENCAO ESPECIALIZADA", "2", "I", 0, 9999 ],
    [ "0301060096", "ATENDIMENTO MEDICO EM UNIDADE DE PRONTO ATENDIMENTO", "2", "I", 0, 9999 ],
    [ "0301100012", "ADMINISTRACAO DE MEDICAMENTOS NA ATENCAO ESPECIALIZADA.", "2", "I", 0, 9999 ],
    [ "0301060118", "ACOLHIMENTO COM CLASSIFICACAO DE RISCO", "2", "I", 0, 9999 ],
    [ "0214010015", "GLICEMIA CAPILAR", "2", "I", 0, 9999 ],
    # Módulo 26a (ADR 0044): procedimentos reguláveis da semente de dev
    # (instrumentos conferidos em vendor/regulation/2026-10-28).
    [ "0301010072", "CONSULTA MEDICA EM ATENCAO ESPECIALIZADA", "2", "I", 0, 9999 ],
    [ "0209010037", "ESOFAGOGASTRODUODENOSCOPIA", "2", "I", 0, 9999 ],
    [ "0401010074", "EXERESE DE TUMOR DE PELE E ANEXOS / CISTO SEBACEO / LIPOMA", "2", "I", 0, 9999 ]
  ].freeze

  # Desvio 14: VL_SA de dev, em centavos (aproximação da tabela vigente).
  AMOUNTS = { "0202020380" => 411, "0202010473" => 185, "0202010503" => 786, "0202010295" => 185, "0202010279" => 351,
              "0202010287" => 351, "0202010678" => 351, "0202010317" => 185, "0202010694" => 185, "0202010643" => 201,
              "0202010651" => 201, "0202060250" => 896, "0202060381" => 1160, "0202060217" => 785, "0202050017" => 370,
              "0202040127" => 165 }.freeze

  LAB_CBOS = %w[221205 223415].freeze

  CBOS = {
    "0301010064" => %w[225125 225142 225130 225170],
    "0301010030" => %w[223505 251510],
    "0201020033" => %w[223505 225125],
    "0301100039" => %w[223505 322205 225125],
    "0301040079" => %w[223505 322205 225125],
    # Módulo 22: UPA e exames do laboratório municipal.
    "0301060029" => %w[225125 225124 225142],
    "0301060096" => %w[225125 225124 225142],
    "0301100012" => %w[223505 322205 225125],
    "0301060118" => %w[223505 225125],
    "0214010015" => %w[223505 322205]
  }.merge(AMOUNTS.keys.to_h { |code| [ code, LAB_CBOS ] }).freeze

  CIDS = { "0201020033" => [ %w[Z014 S] ], "0301060029" => [ %w[I10 S], %w[E119 S], %w[J069 S] ] }.freeze

  INSTRUMENTS = {
    "0301010064" => %w[02], "0301010030" => %w[02], "0201020033" => %w[01 02], "0301100039" => %w[01],
    "0301040079" => %w[01],
    # Módulo 22: BPA-I na consulta/urgência; BPA-C no consolidado e nos exames.
    "0301060029" => %w[02], "0301060096" => %w[02], "0301100012" => %w[01], "0301060118" => %w[01], "0214010015" => %w[01],
    "0203020030" => %w[02],
    # Módulo 26a: BPA (01/02) e, na EGD, AIH especial e APAC (G11: a APAC principal não exclui).
    "0301010072" => %w[01 02 07], "0209010037" => %w[02 04 06 07], "0401010074" => %w[01 02]
  }.merge(AMOUNTS.keys.to_h { |code| [ code, %w[01] ] }).freeze

  REGISTRIES = { "01" => "BPA (CONSOLIDADO)", "02" => "BPA (INDIVIDUALIZADO)", "04" => "AIH (PROC. ESPECIAL)",
                 "06" => "APAC (PROC. PRINCIPAL)", "07" => "APAC (PROC. SECUNDARIO)" }.freeze

  # Módulo 26a: os procedimentos reguláveis do recorte (RegulationCrew).
  REGULATION_CODES = %w[0301010072 0209010037 0401010074].freeze

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
      PROCEDURES.map { |code, name, cx, sex, min, max| [ code, name, cx, sex, 9999, 0, 0, min, max, 0, AMOUNTS.fetch(code, 0), 0, competence ] }
    when "rl_procedimento_ocupacao" then CBOS.flat_map { |code, cbos| cbos.map { |cbo| [ code, cbo, competence ] } }
    when "rl_procedimento_cid" then CIDS.flat_map { |code, cids| cids.map { |cid, principal| [ code, cid, principal, competence ] } }
    when "rl_procedimento_registro" then INSTRUMENTS.flat_map { |code, regs| regs.map { |reg| [ code, reg, competence ] } }
    when "tb_registro" then REGISTRIES.map { |code, name| [ code, name, competence ] }
    end
  end
end
