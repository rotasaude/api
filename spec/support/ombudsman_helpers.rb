require "zlib"

# Módulo 33 (ADR 0051): cidade da ouvidoria (prontuário + interruptores + a
# linha de configuração e a semente de assuntos que o dump não leva), equipe
# (ombudsman, técnico, respondente), setores, cidadão do canal web (par
# declarado), manifestação e anexo gravados direto no banco (os caminhos reais
# são os comandos das Tasks 6–10) e o PNG mínimo em Base64 dos uploads. Tudo
# avaliado só na chamada.
module OmbudsmanHelpers
  BODY = "Fiquei três horas esperando atendimento na unidade de saúde.".freeze

  # Liga `ombudsman` (e, com anonymous: true, `ombudsman_anonymous_web`) e
  # garante a configuração e os assuntos (Ombudsman::Settings, Q13).
  def ombudsman_city!(anonymous: false)
    city = clinical_city!
    Platform::Features.set!(city: city, key: Ombudsman::Gate::KEY, enabled: true, maintainer: ledi_maintainer!)
    Platform::Features.set!(city: city, key: Ombudsman::AnonymousGate::KEY, enabled: true, maintainer: ledi_maintainer!) if anonymous
    Ombudsman::Settings.ensure_defaults!
    CityCatalog.reset_cache!
    city
  end

  # Papéis privilegiados (segundo fator; U3): MFA cadastrado.
  def ombudsman! = (@ombudsman ||= step_up_enrolled!(staff_with("ouvidor-#{SecureRandom.hex(3)}@cidade.gov.br", "ombudsman")))
  def ombudsman_staff! = step_up_enrolled!(staff_with("ouvidoria-#{SecureRandom.hex(3)}@cidade.gov.br", "ombudsman_staff"))
  def ombudsman_admin! = (@ombudsman_admin ||= staff_with("admin-ouvidoria-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin"))

  def department!(name = "Setor #{SecureRandom.hex(3)}") = Department.create!(name: name, updated_by_user: ombudsman_admin!)

  # Usuário com o papel `ombudsman_responder` e a linha ativa no destino (um
  # Department ou uma HealthUnit). Devolve o usuário.
  def responder!(destination)
    user = staff_with("respondente-#{SecureRandom.hex(3)}@cidade.gov.br", "ombudsman_responder")
    key = destination.is_a?(Department) ? :department : :health_unit
    OmbudsmanResponder.create!(user: user, key => destination, created_by_user: ombudsman!)
    user
  end

  # Par declarado do canal web (CPF + telefone), sem consentimento (U1). CPF
  # com dígitos certos, um por chamada.
  def web_citizen!(cpf: ombudsman_cpf!, phone: "+5541998765432", **attrs) = Citizen.create!(cpf: cpf, phone: phone, **attrs)

  def ombudsman_cpf!
    @ombudsman_cpf_seq = (@ombudsman_cpf_seq || 0) + 1
    nums = format("%09d", 731_000_000 + @ombudsman_cpf_seq).chars.map(&:to_i)
    first = CitizenIdentity::Cpf.check_digit(nums)
    (nums + [ first, CitizenIdentity::Cpf.check_digit(nums + [ first ]) ]).join
  end

  # Um subassunto ativo da semente (assunto classificável).
  def subject_leaf!
    OmbudsmanSubject.ensure_defaults!
    OmbudsmanSubject.where(active: true).where.not(parent_id: nil).order(:position, :id).first!
  end

  # Manifestação gravada direto, com protocolo da sequência e o ciclo do dia
  # local do recebimento. Fora do web, o criador é um técnico; no OuvidorSUS,
  # nasce com o número.
  def raw_manifestation!(citizen: nil, channel: "web", created_by_user: (channel == "web" ? nil : ombudsman_staff!),
                         ouvidorsus_number: (channel == "ouvidorsus" ? "OUV-#{SecureRandom.hex(4)}" : nil),
                         received_at: Time.current, protocol: OmbudsmanManifestation.next_protocol(received_at), **attrs)
    OmbudsmanManifestation.create!({ protocol: protocol, kind: "complaint", identification_mode: "identified", channel: channel,
                                     ouvidorsus_number: ouvidorsus_number, citizen: citizen, body: BODY, state: "received",
                                     received_at: received_at, cycle_started_on: received_at.in_time_zone.to_date,
                                     created_by_user: created_by_user }.merge(attrs))
  end

  # Gravação crua (aceita qualquer estado e coluna, para montar cenários); o
  # caminho real do canal web é o Ombudsman::Register (Task 8), coberto por
  # spec/commands/ombudsman/register_spec.rb.
  def manifestation!(**attrs) = raw_manifestation!(**attrs)

  # Anexo com o arquivo PNG do upload: órfão (sem manifestação, arquivo não
  # consumido) ou, com manifestation:, já ligado (arquivo consumido). Dono = a
  # sessão do cidadão (uuid sem FK) ou um técnico.
  def raw_attachment!(manifestation: nil, uploaded_by: "citizen", filename: "anexo-1.png")
    staff = ombudsman_staff! if uploaded_by == "staff"
    bytes = ombudsman_png
    file = ExamFile.create!(content_type: "image/png", byte_size: bytes.bytesize, sha256: Digest::SHA256.hexdigest(bytes),
                            data: Base64.strict_encode64(bytes), purpose: Ombudsman::Catalog::FILE_PURPOSE, uploaded_by_user: staff,
                            consumed_at: (Time.current if manifestation))
    OmbudsmanAttachment.create!(exam_file: file, filename: filename, uploaded_by: uploaded_by, uploaded_by_user: staff,
                                citizen_session_id: (SecureRandom.uuid if uploaded_by == "citizen"), ombudsman_manifestation: manifestation)
  end

  # PNG 1x1 válido (assinatura, IHDR, IDAT e IEND com CRC), em Base64 estrito.
  def png_base64 = Base64.strict_encode64(ombudsman_png)

  def ombudsman_png
    chunk = ->(type, data) { [ data.bytesize ].pack("N") + type + data + [ Zlib.crc32(type + data) ].pack("N") }
    "\x89PNG\r\n\x1a\n".b + chunk.call("IHDR".b, [ 1, 1, 8, 2, 0, 0, 0 ].pack("NNCCCCC")) +
      chunk.call("IDAT".b, Zlib::Deflate.deflate("\x00\xff\xff\xff".b)) + chunk.call("IEND".b, "".b)
  end
end

RSpec.configure { |c| c.include OmbudsmanHelpers }
