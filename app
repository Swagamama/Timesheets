#!/usr/bin/env python3
"""
Rohan's Timesheet Tracker
A Flask web application to parse PDF timesheets and extract work schedules.
"""

from flask import Flask, request, render_template_string, jsonify, send_from_directory
import PyPDF2
import pdfplumber
import re
import json
import os
from datetime import datetime, timedelta
from werkzeug.utils import secure_filename
import sqlite3
from pathlib import Path

app = Flask(__name__)
app.config['UPLOAD_FOLDER'] = 'uploads'
app.config['MAX_CONTENT_LENGTH'] = 16 * 1024 * 1024  # 16MB max file size

# Ensure upload directory exists
Path(app.config['UPLOAD_FOLDER']).mkdir(exist_ok=True)

class TimesheetParser:
    def __init__(self):
        self.day_names = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday']
    
    def extract_text_from_pdf(self, pdf_path):
        """Extract text from PDF using pdfplumber for better accuracy"""
        text = ""
        try:
            with pdfplumber.open(pdf_path) as pdf:
                for page in pdf.pages:
                    page_text = page.extract_text()
                    if page_text:
                        text += page_text + "\n"
        except Exception as e:
            print(f"Error with pdfplumber: {e}")
            # Fallback to PyPDF2
            try:
                with open(pdf_path, 'rb') as file:
                    pdf_reader = PyPDF2.PdfReader(file)
                    for page in pdf_reader.pages:
                        text += page.extract_text() + "\n"
            except Exception as e2:
                print(f"Error with PyPDF2: {e2}")
                raise Exception("Could not extract text from PDF")
        
        return text
    
    def find_week_ending(self, text):
        """Extract week ending date from timesheet"""
        patterns = [
            r'Week ending (\d{1,2}/\d{1,2}/\d{4})',
            r'Week ending (\d{1,2}\.\d{1,2}\.\d{4})',
            r'Week ending (\d{1,2}-\d{1,2}-\d{4})',
        ]
        
        for pattern in patterns:
            match = re.search(pattern, text, re.IGNORECASE)
            if match:
                return match.group(1)
        
        return "Current Week"
    
    def extract_rohan_schedule(self, text):
        """Extract Rohan's work schedule from the timesheet text"""
        lines = [line.strip() for line in text.split('\n') if line.strip()]
        
        schedule = {
            'weekEnding': self.find_week_ending(text),
            'days': []
        }
        
        print("=== PDF TEXT DEBUG ===")
        print(f"Total lines: {len(lines)}")
        
        # Find all time ranges and their associated Rohan entries
        rohan_entries = []
        
        for i, line in enumerate(lines):
            # Look for time range patterns
            time_match = re.search(r'(\d{1,2}:\d{2}-\d{1,2}:\d{2})', line)
            
            if time_match:
                time_range = time_match.group(1)
                start_time = time_range.split('-')[0]
                
                print(f"Line {i}: Found time range '{time_range}' in: {line}")
                
                # Look in the next several lines for Rohan
                for j in range(i + 1, min(i + 15, len(lines))):
                    next_line = lines[j]
                    
                    if 'Rohan' in next_line:
                        print(f"Line {j}: Found Rohan in: {next_line}")
                        
                        # Extract notes
                        note = self.extract_note_from_line(next_line)
                        
                        rohan_entries.append({
                            'time_range': time_range,
                            'start_time': start_time,
                            'note': note,
                            'line': next_line,
                            'line_index': j
                        })
                        
                        print(f"Added entry: {start_time} with note '{note}'")
                        break
                    
                    # Stop if we hit another time range or section
                    if re.search(r'\d{1,2}:\d{2}-\d{1,2}:\d{2}', next_line):
                        break
                    if re.search(r'^(ATM|Packer|Batching|Dispatch)', next_line):
                        break
        
        print(f"\nFound {len(rohan_entries)} Rohan entries:")
        for entry in rohan_entries:
            print(f"  {entry['start_time']} - {entry['note']} - {entry['line']}")
        
        # Remove duplicates and assign to days
        unique_entries = self.deduplicate_entries(rohan_entries)
        
        # Sort by line appearance order
        unique_entries.sort(key=lambda x: x['line_index'])
        
        # Assign to Monday-Friday based on order
        for i, entry in enumerate(unique_entries):
            if i < len(self.day_names):
                schedule['days'].append({
                    'day': self.day_names[i],
                    'time': entry['start_time'],
                    'note': entry['note']
                })
        
        print(f"\nFinal schedule: {schedule}")
        return schedule
    
    def extract_note_from_line(self, line):
        """Extract notes like (ATM), abbreviations, etc. from a line containing Rohan"""
        note_patterns = [
            r'\(([^)]+)\)',  # Text in parentheses
            r'Rohan\s*\(([^)]+)\)',  # Rohan(ATM)
            r'Rohan\s+([A-Z]{2,4})(?:\s|$)',  # Rohan ATM
            r'([A-Z]{2,4})\s+Rohan',  # ATM Rohan
            r'Rohan\s*([A-Z]{2,4})\s*\(',  # Rohan ATM(
        ]
        
        for pattern in note_patterns:
            match = re.search(pattern, line)
            if match:
                return match.group(1).strip()
        
        return ""
    
    def deduplicate_entries(self, entries):
        """Remove duplicate entries, preferring those with notes"""
        if not entries:
            return []
        
        # Group by start time
        time_groups = {}
        for entry in entries:
            time = entry['start_time']
            if time not in time_groups:
                time_groups[time] = []
            time_groups[time].append(entry)
        
        unique_entries = []
        for time, group in time_groups.items():
            # Prefer entry with note, otherwise take the first one
            best_entry = None
            for entry in group:
                if not best_entry:
                    best_entry = entry
                elif entry['note'] and not best_entry['note']:
                    best_entry = entry
            
            if best_entry:
                unique_entries.append(best_entry)
        
        return unique_entries

class TimesheetDatabase:
    def __init__(self, db_path='timesheets.db'):
        self.db_path = db_path
        self.init_db()
    
    def init_db(self):
        """Initialize the database"""
        conn = sqlite3.connect(self.db_path)
        cursor = conn.cursor()
        
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS timesheets (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                week_ending TEXT NOT NULL,
                schedule_data TEXT NOT NULL,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                is_current BOOLEAN DEFAULT 0
            )
        ''')
        
        conn.commit()
        conn.close()
    
    def save_schedule(self, schedule):
        """Save a schedule to the database"""
        conn = sqlite3.connect(self.db_path)
        cursor = conn.cursor()
        
        # Remove existing entry for this week
        cursor.execute('DELETE FROM timesheets WHERE week_ending = ?', (schedule['weekEnding'],))
        
        # Insert new entry
        cursor.execute('''
            INSERT INTO timesheets (week_ending, schedule_data, is_current)
            VALUES (?, ?, ?)
        ''', (schedule['weekEnding'], json.dumps(schedule), self.is_current_week(schedule['weekEnding'])))
        
        conn.commit()
        conn.close()
    
    def get_all_schedules(self):
        """Get all saved schedules"""
        conn = sqlite3.connect(self.db_path)
        cursor = conn.cursor()
        
        cursor.execute('''
            SELECT week_ending, schedule_data, created_at, is_current
            FROM timesheets
            ORDER BY created_at DESC
        ''')
        
        schedules = []
        for row in cursor.fetchall():
            schedule_data = json.loads(row[1])
            schedule_data['created_at'] = row[2]
            schedule_data['is_current'] = bool(row[3])
            schedules.append(schedule_data)
        
        conn.close()
        return schedules
    
    def clear_history(self):
        """Clear all saved schedules"""
        conn = sqlite3.connect(self.db_path)
        cursor = conn.cursor()
        cursor.execute('DELETE FROM timesheets')
        conn.commit()
        conn.close()
    
    def is_current_week(self, week_ending_str):
        """Check if the given week ending represents the current week"""
        if week_ending_str == 'Current Week':
            return True
        
        try:
            # Parse different date formats
            for fmt in ['%d/%m/%Y', '%d.%m.%Y', '%d-%m-%Y']:
                try:
                    week_ending = datetime.strptime(week_ending_str, fmt)
                    break
                except ValueError:
                    continue
            else:
                return False
            
            # Check if current date falls within this week (assuming Saturday to Friday)
            today = datetime.now()
            week_start = week_ending - timedelta(days=6)
            
            return week_start.date() <= today.date() <= week_ending.date()
        except:
            return False

# Initialize components
parser = TimesheetParser()
db = TimesheetDatabase()

@app.route('/')
def index():
    """Main page with timesheet tracker interface"""
    return render_template_string('''
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Rohan's Timesheet Tracker</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }

        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            padding: 20px;
        }

        .container {
            max-width: 500px;
            margin: 0 auto;
            background: rgba(255, 255, 255, 0.95);
            border-radius: 20px;
            backdrop-filter: blur(10px);
            box-shadow: 0 20px 40px rgba(0, 0, 0, 0.1);
            overflow: hidden;
        }

        .header {
            background: linear-gradient(135deg, #4facfe 0%, #00f2fe 100%);
            padding: 30px 20px;
            color: white;
            text-align: center;
        }

        .header h1 {
            font-size: 24px;
            font-weight: 700;
            margin-bottom: 5px;
        }

        .header p {
            opacity: 0.9;
            font-size: 14px;
        }

        .upload-section {
            padding: 30px 20px;
            text-align: center;
        }

        .upload-area {
            border: 3px dashed #4facfe;
            border-radius: 15px;
            padding: 40px 20px;
            margin-bottom: 20px;
            cursor: pointer;
            transition: all 0.3s ease;
            background: #f8fbff;
        }

        .upload-area:hover {
            border-color: #667eea;
            background: #f0f8ff;
            transform: translateY(-2px);
        }

        .upload-icon {
            font-size: 48px;
            margin-bottom: 15px;
            color: #4facfe;
        }

        .upload-text {
            color: #666;
            font-size: 16px;
            margin-bottom: 10px;
        }

        .upload-subtext {
            color: #999;
            font-size: 14px;
        }

        #fileInput {
            display: none;
        }

        .btn {
            background: linear-gradient(135deg, #4facfe 0%, #00f2fe 100%);
            color: white;
            border: none;
            padding: 12px 24px;
            border-radius: 25px;
            cursor: pointer;
            font-size: 14px;
            font-weight: 600;
            transition: all 0.3s ease;
            box-shadow: 0 4px 15px rgba(79, 172, 254, 0.4);
        }

        .btn:hover:not(:disabled) {
            transform: translateY(-2px);
            box-shadow: 0 6px 20px rgba(79, 172, 254, 0.6);
        }

        .btn:disabled {
            opacity: 0.6;
            cursor: not-allowed;
            transform: none;
        }

        .timesheet-display {
            padding: 20px;
            display: none;
        }

        .week-header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 15px;
            border-radius: 15px;
            margin-bottom: 20px;
            text-align: center;
            position: relative;
        }

        .current-week {
            background: linear-gradient(135deg, #11998e 0%, #38ef7d 100%);
            animation: pulse 2s infinite;
        }

        @keyframes pulse {
            0% { transform: scale(1); }
            50% { transform: scale(1.02); }
            100% { transform: scale(1); }
        }

        .current-indicator {
            position: absolute;
            top: -8px;
            right: -8px;
            background: #ff6b6b;
            color: white;
            padding: 4px 8px;
            border-radius: 10px;
            font-size: 12px;
            font-weight: bold;
        }

        .day-card {
            background: white;
            border-radius: 15px;
            padding: 15px;
            margin-bottom: 12px;
            box-shadow: 0 4px 15px rgba(0, 0, 0, 0.08);
            border-left: 4px solid #4facfe;
            transition: all 0.3s ease;
        }

        .day-card:hover {
            transform: translateX(5px);
            box-shadow: 0 6px 20px rgba(0, 0, 0, 0.12);
        }

        .day-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 8px;
        }

        .day-name {
            font-weight: 700;
            color: #333;
            font-size: 16px;
        }

        .day-time {
            background: linear-gradient(135deg, #4facfe 0%, #00f2fe 100%);
            color: white;
            padding: 4px 12px;
            border-radius: 20px;
            font-weight: 600;
            font-size: 14px;
        }

        .day-note {
            background: #fff3cd;
            color: #856404;
            padding: 6px 12px;
            border-radius: 10px;
            font-size: 12px;
            font-weight: 500;
            border-left: 3px solid #ffc107;
        }

        .history-section {
            margin-top: 30px;
            padding: 20px;
            border-top: 1px solid #eee;
        }

        .history-title {
            font-size: 18px;
            font-weight: 700;
            color: #333;
            margin-bottom: 15px;
        }

        .clear-history {
            background: #ff6b6b;
            color: white;
            border: none;
            padding: 8px 16px;
            border-radius: 15px;
            cursor: pointer;
            font-size: 12px;
            margin-left: 10px;
        }

        .loading {
            text-align: center;
            padding: 20px;
            color: #666;
        }

        .error {
            background: #ffe6e6;
            color: #d63384;
            padding: 15px;
            border-radius: 10px;
            margin: 15px;
            border-left: 4px solid #d63384;
        }

        .success {
            background: #e6f7e6;
            color: #0d7c0d;
            padding: 15px;
            border-radius: 10px;
            margin: 15px;
            border-left: 4px solid #0d7c0d;
        }

        .spinner {
            border: 3px solid #f3f3f3;
            border-top: 3px solid #4facfe;
            border-radius: 50%;
            width: 30px;
            height: 30px;
            animation: spin 1s linear infinite;
            margin: 0 auto 10px;
        }

        @keyframes spin {
            0% { transform: rotate(0deg); }
            100% { transform: rotate(360deg); }
        }

        @media (max-width: 480px) {
            .container {
                margin: 0;
                border-radius: 0;
                min-height: 100vh;
            }

            .upload-area {
                padding: 30px 15px;
            }

            .day-header {
                flex-direction: column;
                align-items: flex-start;
                gap: 8px;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>Rohan's Timesheet Tracker</h1>
            <p>Upload your weekly timesheet PDF - Python powered parsing</p>
        </div>

        <div class="upload-section">
            <div class="upload-area" onclick="document.getElementById('fileInput').click()">
                <div class="upload-icon">📄</div>
                <div class="upload-text">Drop your timesheet PDF here</div>
                <div class="upload-subtext">or click to browse</div>
            </div>
            <form id="uploadForm" enctype="multipart/form-data">
                <input type="file" id="fileInput" name="file" accept=".pdf" />
                <button type="submit" class="btn" id="uploadBtn">
                    Upload & Parse PDF
                </button>
            </form>
        </div>

        <div id="messages"></div>
        <div id="timesheetDisplay" class="timesheet-display"></div>
    </div>

    <script>
        const form = document.getElementById('uploadForm');
        const fileInput = document.getElementById('fileInput');
        const uploadBtn = document.getElementById('uploadBtn');
        const messages = document.getElementById('messages');
        const display = document.getElementById('timesheetDisplay');

        form.addEventListener('submit', async (e) => {
            e.preventDefault();
            
            const file = fileInput.files[0];
            if (!file) {
                showError('Please select a PDF file');
                return;
            }

            if (file.type !== 'application/pdf') {
                showError('Please select a valid PDF file');
                return;
            }

            showLoading();
            
            const formData = new FormData();
            formData.append('file', file);

            try {
                const response = await fetch('/upload', {
                    method: 'POST',
                    body: formData
                });

                const result = await response.json();

                if (result.success) {
                    showSuccess('PDF processed successfully!');
                    displayTimesheet(result.schedule);
                    loadHistory();
                } else {
                    showError(result.error || 'Failed to process PDF');
                }
            } catch (error) {
                console.error('Upload error:', error);
                showError('Failed to upload file. Please try again.');
            }
        });

        async function loadHistory() {
            try {
                const response = await fetch('/history');
                const result = await response.json();
                if (result.success && result.schedules.length > 0) {
                    displayHistory(result.schedules);
                }
            } catch (error) {
                console.error('Error loading history:', error);
            }
        }

        async function clearHistory() {
            if (confirm('Are you sure you want to clear all history?')) {
                try {
                    const response = await fetch('/clear-history', { method: 'POST' });
                    const result = await response.json();
                    if (result.success) {
                        location.reload();
                    }
                } catch (error) {
                    console.error('Error clearing history:', error);
                }
            }
        }

        function displayTimesheet(schedule) {
            let html = `
                <div class="week-header ${schedule.is_current ? 'current-week' : ''}">
                    ${schedule.is_current ? '<div class="current-indicator">CURRENT</div>' : ''}
                    <h2>Week Ending: ${schedule.weekEnding}</h2>
                </div>
            `;

            schedule.days.forEach(day => {
                html += `
                    <div class="day-card">
                        <div class="day-header">
                            <div class="day-name">${day.day}</div>
                            <div class="day-time">${day.time}</div>
                        </div>
                        ${day.note ? `<div class="day-note">Note: ${day.note}</div>` : ''}
                    </div>
                `;
            });

            display.innerHTML = html;
            display.style.display = 'block';
        }

        function displayHistory(schedules) {
            if (schedules.length <= 1) return; // Only current schedule

            let historyHtml = `
                <div class="history-section">
                    <h3 class="history-title">
                        Previous Weeks
                        <button class="clear-history" onclick="clearHistory()">Clear All</button>
                    </h3>
            `;

            schedules.slice(1).forEach(schedule => {
                historyHtml += `
                    <div class="week-header ${schedule.is_current ? 'current-week' : ''}" style="margin-top: 15px;">
                        ${schedule.is_current ? '<div class="current-indicator">CURRENT</div>' : ''}
                        <h4>Week Ending: ${schedule.weekEnding}</h4>
                    </div>
                `;
                
                schedule.days.forEach(day => {
                    historyHtml += `
                        <div class="day-card">
                            <div class="day-header">
                                <div class="day-name">${day.day}</div>
                                <div class="day-time">${day.time}</div>
                            </div>
                            ${day.note ? `<div class="day-note">Note: ${day.note}</div>` : ''}
                        </div>
                    `;
                });
            });

            historyHtml += '</div>';
            display.innerHTML += historyHtml;
        }

        function showLoading() {
            messages.innerHTML = `
                <div class="loading">
                    <div class="spinner"></div>
                    <p>Processing your timesheet with Python...</p>
                </div>
            `;
            uploadBtn.disabled = true;
            display.style.display = 'none';
        }

        function showError(message) {
            messages.innerHTML = `<div class="error"><strong>Error:</strong> ${message}</div>`;
            uploadBtn.disabled = false;
        }

        function showSuccess(message) {
            messages.innerHTML = `<div class="success"><strong>Success:</strong> ${message}</div>`;
            uploadBtn.disabled = false;
        }

        // Load history on page load
        window.addEventListener('load', loadHistory);
    </script>
</body>
</html>
    ''')

@app.route('/upload', methods=['POST'])
def upload_file():
    """Handle PDF upload and parsing"""
    try:
        if 'file' not in request.files:
            return jsonify({'success': False, 'error': 'No file uploaded'})
        
        file = request.files['file']
        if file.filename == '':
            return jsonify({'success': False, 'error': 'No file selected'})
        
        if not file.filename.lower().endswith('.pdf'):
            return jsonify({'success': False, 'error': 'Please upload a PDF file'})
        
        # Save uploaded file
        filename = secure_filename(file.filename)
        filepath = os.path.join(app.config['UPLOAD_FOLDER'], filename)
        file.save(filepath)
        
        # Parse the PDF
        schedule = parser.extract_rohan_schedule(parser.extract_text_from_pdf(filepath))
        
        if not schedule['days']:
            return jsonify({
                'success': False, 
                'error': 'Could not find your schedule in the PDF. Make sure "Rohan" appears in the timesheet.'
            })
        
        # Add current week flag
        schedule['is_current'] = db.is_current_week(schedule['weekEnding'])
        
        # Save to database
        db.save_schedule(schedule)
        
        # Clean up uploaded file
        os.remove(filepath)
        
        return jsonify({'success': True, 'schedule': schedule})
        
    except Exception as e:
        print(f"Error processing upload: {e}")
        return jsonify({'success': False, 'error': f'Failed to process PDF: {str(e)}'})

@app.route('/history')
def get_history():
    """Get saved timesheet history"""
    try:
        schedules = db.get_all_schedules()
        return jsonify({'success': True, 'schedules': schedules})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

@app.route('/clear-history', methods=['POST'])
def clear_history():
    """Clear all saved timesheets"""
    try:
        db.clear_history()
        return jsonify({'success': True})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

if __name__ == '__main__':
    print("Starting Rohan's Timesheet Tracker...")
    print("Make sure you have the required packages installed:")
    print("pip install flask PyPDF2 pdfplumber")
    print("\nServer will start at http://localhost:5000")
    
    app.run(debug=True, host='0.0.0.0', port=5000)
