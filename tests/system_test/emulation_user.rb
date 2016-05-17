require 'rest-client'
require 'figaro'
unless Figaro.application.environment
  Figaro.application =
      Figaro::Application.new(environment: "development", path: "../../config/application.yml")
  Figaro.load
end
require "#{ENV['root']}/config/common_requirement"

SERVICE_ADDRESS = 'localhost:9292'
USER_TOKEN = '86e81d58-5de3-47b5-9f40-6c430933aa6a'

def one_user (input_filename, out_extension)
  start_time = Time.now

  input_extension = File.extname("#{ENV['root']}/test_files/#{input_filename}")[1..-1]
  begin
    response = RestClient.post "http://#{SERVICE_ADDRESS}/convert_file",
                               input_extension: input_extension,
                               output_extension: out_extension,
                               file: File.new("#{ENV['root']}/test_files/#{input_filename}", 'rb')
    if JSON.parse(response)['id']
      task_id = JSON.parse(response)['id']
      puts "Task #{task_id} successful created."
      succ_finished = false
      3000.times do
        begin
          response = RestClient.get "http://#{SERVICE_ADDRESS}/state/#{task_id}"
          state_task = JSON.parse(response)['state']
          if state_task == ConvertState::FINISHED
            succ_finished = true
            break
          end
        rescue => e
          puts "Bad request id: #{task_id unless task_id.nil?} #{[e.response.code,
                                                                  e.response.cookies,
                                                                  e.response.headers].join("\n")}"
          break

        end
        sleep 0.5
      end

      if succ_finished
        File.open("#{ENV['root']}/tests/download/#{File.basename(input_filename, ".*")}_#{task_id}.#{out_extension}", 'w') do |f|
          RestClient.get "http://#{SERVICE_ADDRESS}/get_converted_file/#{task_id}" do |str|
            f.write str
          end
        end
        puts "Task #{task_id} successful downloaded."
      else
        puts 'Conversation was failed.'
      end
    else
      puts 'Result does not exists.'
    end
  rescue => e
    puts "Bad request: #{e}"
  end

  end_time = Time.now
  (end_time-start_time).to_f
end

25.times do
  Process.fork do
    puts one_user('test_1.odt', 'pdf')
  end
  Process.fork do
    puts one_user('test_2.doc', 'pdf')
  end
  Process.fork do
    puts one_user('test_3.txt', 'pdf')
  end
  Process.fork do
    puts one_user('test_4.jpg', 'bmp')
  end
end

Process.waitall