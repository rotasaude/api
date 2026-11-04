# Ficha espelho da RAAS do mês (ADR 0049; contrato §6, P14; plano, Desvio 10).
# A4 da folha de Consultations::Print.document (fonte embutida, texto por
# `safe`). Uma página por registro (a que transborda continua em páginas que
# repetem o nome e o CNS mascarado), com os blocos na ordem das telas do
# aplicativo RAAS — Identificação, Dados do atendimento, Ações — e só os campos
# que o aplicativo pede: nunca a evolução (notes), o PTS, o motivo do
# encaminhamento nem o texto do matriciamento. Com o mês aberto (`preview`), a
# marca "PRÉVIA" no topo de cada página (os dados já vêm ao vivo de
# RaasRecords). Gera bytes; nada é gravado nem logado.
module Psychosocial
  module MirrorSheetPdf
    Footer = Data.define(:text)
    FOOTER = Footer.new("Ficha espelho da RAAS (Atenção Psicossocial). Conferência para digitação no aplicativo RAAS; " \
                        "contém dado pessoal e de saúde: uso restrito.").freeze
    TITLE = "Ficha espelho da RAAS".freeze
    PREVIEW = "PRÉVIA".freeze
    # Raça/cor nos códigos do BPA/RAAS (Patient::RACE_COLORS).
    RACE_COLORS = { "01" => "Branca", "02" => "Preta", "03" => "Parda", "04" => "Amarela", "05" => "Indígena" }.freeze
    SEXES = { "male" => "Masculino", "female" => "Feminino" }.freeze
    PLACES = { "caps" => "CAPS", "territory" => "Território" }.freeze
    # Espaço mínimo (pontos) para um bloco de ação (data e detalhe, que pode
    # quebrar em duas linhas); abaixo disso, a ação vai para a página seguinte,
    # que abre com o cabeçalho de continuação (nenhuma página sem identificação).
    ACTION_MIN_SPACE = 48

    module_function

    # records: [RaasRecords::Entry]; unit: o CAPS; month: dia 1º. -> String (bytes do PDF)
    def call(records:, preview:, unit:, month:)
      pdf = Consultations::Print.document(FOOTER, title: TITLE)
      stamp_preview(pdf) if preview
      cache = Billing::SigtapCache.new
      if records.empty?
        heading(pdf, unit, month)
        pdf.text s("Nenhum registro com ação RAAS no mês.")
      end
      records.each_with_index do |entry, index|
        pdf.start_new_page if index.positive?
        sheet(pdf, entry, unit, month, cache)
      end
      pdf.render
    end

    def sheet(pdf, entry, unit, month, cache)
      data = entry.data
      heading(pdf, unit, month)
      identification(pdf, data)
      attendance(pdf, data, unit, month)
      actions(pdf, entry, month, cache)
    end

    def heading(pdf, unit, month)
      pdf.move_down 14
      pdf.text s(TITLE.upcase), style: :bold, size: 13
      pdf.text s("#{unit.name} — CNES #{unit.cnes}    Mês de atendimento: #{month.strftime('%m/%Y')}")
    end

    def identification(pdf, data)
      patient = data.fetch("patient")
      address = patient["address"] || {}
      block(pdf, "Identificação")
      line(pdf, "Nome", patient["name"])
      line(pdf, "Nome social", patient["social_name"]) if patient["social_name"].present?
      line(pdf, "CNS", patient["cns"])
      line(pdf, "Data de nascimento", date(patient["birth_date"]))
      line(pdf, "Sexo", SEXES.fetch(patient["sex"].to_s, patient["sex"]))
      line(pdf, "Nome da mãe", patient["mother_name"])
      line(pdf, "Raça/cor", coded(patient["race_color"], RACE_COLORS[patient["race_color"].to_s]))
      line(pdf, "Etnia", patient["ethnicity"])
      line(pdf, "Telefone", patient["phone"])
      line(pdf, "Endereço", [ address["street"], address["number"], address["complement"], address["district"] ].compact_blank.join(", "))
      line(pdf, "CEP", address["zip"])
    end

    def attendance(pdf, data, unit, month)
      block(pdf, "Dados do atendimento")
      line(pdf, "Estabelecimento", "#{unit.cnes} — #{unit.name}")
      line(pdf, "Competência de atendimento", month.strftime("%m/%Y"))
      line(pdf, "Data de início", date(data["started_on"]))
      line(pdf, "Origem", coded(data["origin"], Raas.label(:origins, data["origin"].to_s))) if data["initial"]
      line(pdf, "CID principal", data["cid_main"])
      line(pdf, "CIDs secundários", Array(data["cid_secondary"]).join(", "))
      line(pdf, "Substâncias", Array(data["substances"]).map { |code| coded(code, Raas.label(:substances, code.to_s)) }.join(", "))
      line(pdf, "Cobertura por ESF", esf(data))
      line(pdf, "Situação de rua", { true => "Sim", false => "Não" }.fetch(data["homeless"], nil))
      line(pdf, "Destino", coded(data["destination"], Raas.label(:destinations, data["destination"].to_s)))
      line(pdf, "Data de conclusão", date(data["concluded_on"])) if data["concluded_on"]
    end

    def actions(pdf, entry, month, cache)
      block(pdf, "Ações")
      release = cache.release(month.strftime("%Y%m"))
      entry.actions.each do |action|
        continuation(pdf, entry.data) if pdf.cursor < ACTION_MIN_SPACE
        name = release && cache.procedure(release, action["sigtap_code"])&.name
        pdf.move_down 4
        pdf.text s("#{date(action['performed_on'])} — #{action['sigtap_code']}#{" #{name}" if name}"), style: :bold
        pdf.text s("CBO #{action['cbo_code']}    CNS do profissional: #{action['professional_cns'] || 'não informado'}    " \
                   "Quantidade: #{action['quantity']}    Local: #{PLACES.fetch(action['place'], action['place'])}" \
                   "#{"    Autorização: #{action['authorization_number']}" if action['authorization_number']}")
      end
    end

    # Página de continuação de um registro: o bloco, o nome e o CNS mascarado.
    def continuation(pdf, data)
      patient = data.fetch("patient")
      cns = Professionals::Cns.mask(patient["cns"]) || "não informado"
      pdf.start_new_page
      pdf.move_down 14
      pdf.text s("Ações (continuação) — #{patient['name']} — CNS #{cns}"), style: :bold, size: 11
    end

    # "PRÉVIA" no topo de cada página (inclusive as criadas depois), fora do fluxo do texto.
    def stamp_preview(pdf)
      width = pdf.bounds.width
      pdf.repeat(:all) do
        pdf.float do
          pdf.canvas do
            pdf.bounding_box([ 40, pdf.bounds.top - 20 ], width: width, height: 20) do
              pdf.text s("#{PREVIEW} — mês aberto: dados ao vivo, sujeitos a mudança até o fechamento"), style: :bold, size: 9
            end
          end
        end
      end
    end

    def block(pdf, title)
      pdf.move_down 10
      pdf.text s(title), style: :bold, size: 11
    end

    def line(pdf, label, value) = pdf.text(s("#{label}: #{value.presence || 'não informado'}"))
    def coded(code, label) = code.blank? ? nil : [ code, label ].compact.join(" — ")
    def esf(data) = data["esf_covered"] ? [ "Sim", data["esf_cnes"] && "CNES #{data['esf_cnes']}" ].compact.join(", ") : "Não"
    def date(value) = value.present? ? Date.iso8601(value.to_s).strftime("%d/%m/%Y") : nil
    def s(text) = Consultations::Print.safe(text)
  end
end
