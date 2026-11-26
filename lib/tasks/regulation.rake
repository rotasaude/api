namespace :regulation do
  desc "Writes the in-memory RIRA example documents (no database) for the official HL7 validator; prints file names only"
  task :rira_examples, [ :dir ] => :environment do |_task, args|
    dir = args[:dir].presence || "tmp/rira-examples"
    Regulation::RiraExamples.write(Rails.root.join(dir), now: Time.current).each { |path| puts path.basename }
  end
end
