#coding: utf-8

##########################################################
#
#聖書のテキストデータをCSVに変換するプログラム
#
##########################################################

require 'kconv'
require 'csv'

DEBUG = false

#聖書データのフォルダ名
DATA_DIR = "bomdata"
#聖書のファイル名のプレフィックス
BIBLE_PREFIX = "bible"

#出力先CSVファイルのファイル名
#新約聖書のCSV
NEW_OUTPUT_CSV_FILE = "new.csv"
#旧約聖書のCSV
OLD_OUTPUT_CSV_FILE = "old.csv"

#新約か旧約か
NEW_BIBLE = 0
OLD_BIBLE = 1

#（デバッグ用）聖典のデータを標準出力する
def print_data(data)
	print "[",data[:type],"]"
	print "(",data[:book],")",data[:chapter],":"
	puts data[:verse]
	puts data[:text]
end

def get_bible(flag)

	data_arr = []
	
	case flag
	when NEW_BIBLE
		(40..66).each_with_index do |i,book_id|
			filename = DATA_DIR+'/'+BIBLE_PREFIX+sprintf("%02d",i)+'.txt'
			textdata = open(filename).read.toutf8.split(/\n/)
			
			textdata.each do |line|
				if line =~ /^(\d+):(\d+)\s(.+)$/
					data = {book: book_id,chapter: $1, verse: $2, type: 'verse',text: $3}
					print_data data if DEBUG
					data_arr.push data
				end
			end
		end
	when OLD_BIBLE
		(1..39).each_with_index do |i,book_id|
			filename = DATA_DIR+'/'+BIBLE_PREFIX+sprintf("%02d",i)+'.txt'
			textdata = open(filename).read.toutf8.split(/\n/)
			
			textdata.each do |line|
				if line =~ /^(\d+):(\d+)\s(.+)$/
					data = {book: book_id,chapter: $1, verse: $2, type: 'verse',text: $3}
					print_data data if DEBUG
					data_arr.push data
				end
			end
		end
	end
	data_arr
end


def write_scripture_csv(output_csv_file,scripture_data)
	CSV.open(output_csv_file,'w') do |writer|
		scripture_data.each do |data|
			writer << [data[:book],data[:chapter],data[:verse],data[:type],data[:text]]
		end
	end
end

#新約聖書データを取得しCSVに出力
puts "reading 'New Bible' data"
new = get_bible NEW_BIBLE
puts "writing 'New Bible' data to #{NEW_OUTPUT_CSV_FILE}"
write_scripture_csv(NEW_OUTPUT_CSV_FILE,new) unless DEBUG
puts "Completed!"

#旧約聖書データを取得しCSVに出力
puts "reading 'Old Bible' data"
old = get_bible OLD_BIBLE
puts "writing 'Old Bible' data to #{OLD_OUTPUT_CSV_FILE}"
write_scripture_csv(OLD_OUTPUT_CSV_FILE,old) unless DEBUG
puts "Completed!"

