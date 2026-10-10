# spec/services/clinical_documents/issuers_spec.rb
require "rails_helper"

# Spec §4 (Desvio 9): atestado só médico (2251–2253) e dentista (2232);
# receita médico, dentista e enfermeiro (2235, por protocolo); declaração e
# requisição, a autora da consulta. Declaração pelo atendimento: recepção ou
# profissional com vínculo ativo na unidade.
RSpec.describe ClinicalDocuments::Issuers do
  def self.matrix = {
    "225125" => [ :physician, { "sick_note" => true, "prescription" => true } ],
    "225250" => [ :physician, { "sick_note" => true, "prescription" => true } ],
    "225320" => [ :physician, { "sick_note" => true, "prescription" => true } ],
    "223208" => [ :dentist, { "sick_note" => true, "prescription" => true } ],
    "223505" => [ :nurse, { "sick_note" => false, "prescription" => true } ],
    "223605" => [ :other, { "sick_note" => false, "prescription" => false } ],
    "251510" => [ :other, { "sick_note" => false, "prescription" => false } ]
  }

  matrix.each do |cbo, (role, kinds)|
    it "CBO #{cbo}: #{role}" do
      expect(described_class.role(cbo)).to eq(role)
      kinds.each { |kind, allowed| expect(described_class.allowed?(kind, cbo)).to be(allowed), "#{kind} #{cbo}" }
      expect(described_class.allowed?("attendance_declaration", cbo)).to be(true)
      expect(described_class.allowed?("exam_requisition", cbo)).to be(true)
    end
  end

  describe ".declaration_staff" do
    before { clinical_city! }

    let(:unit) { create_unit }
    let(:attendance) { walk_in_attendance!(unit, citizen: verified_citizen!(1)) }

    it "recepção sem CBO; profissional com vínculo na unidade com o CBO; o resto recusado" do
      expect(described_class.declaration_staff(verifier!, attendance)).to eq([ :ok, nil ])
      expect(described_class.declaration_staff(nurse!(unit), attendance)).to eq([ :ok, "223505" ])
      expect(described_class.declaration_staff(doctor!(create_unit("UBS Norte")), attendance)).to eq([ :missing_role, nil ])
      expect(described_class.declaration_staff(municipal_admin!, attendance)).to eq([ :missing_role, nil ])
    end
  end
end
