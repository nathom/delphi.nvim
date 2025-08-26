import os
import shutil
import datetime
import collections

def organize_files_by_extension(source_directory, destination_base_directory=None):
    """
    Organizes files in a given directory into subfolders based on their file extension.

    Args:
        source_directory (str): The path to the directory to organize.
        destination_base_directory (str, optional): The base directory where
                                                    extension-based subfolders
                                                    will be created. If None,
                                                    subfolders are created
                                                    within the source_directory.
    """
    if not os.path.isdir(source_directory):
        print(f"Error: Source directory '{source_directory}' not found for extension organization.")
        return

    if destination_base_directory and not os.path.isdir(destination_base_directory):
        try:
            os.makedirs(destination_base_directory, exist_ok=True)
            print(f"Created base destination directory: '{destination_base_directory}'")
        except OSError as e:
            print(f"Error creating destination base directory '{destination_base_directory}': {e}")
            return

    print(f"Starting file organization by extension in: {source_directory}")
    print("-" * 50)

    organized_count = 0
    skipped_count = 0
    error_count = 0

    for filename in os.listdir(source_directory):
        file_path = os.path.join(source_directory, filename)

        if os.path.isdir(file_path):
            print(f"Skipping directory: {filename}")
            skipped_count += 1
            continue

        try:
            _, ext = os.path.splitext(filename)
            ext_name = ext.lower().lstrip('.') # Remove leading dot for folder name

            if not ext_name: # Handle files with no extension
                ext_name = "no_extension"

            if destination_base_directory:
                destination_dir = os.path.join(destination_base_directory, ext_name)
            else:
                destination_dir = os.path.join(source_directory, ext_name)

            os.makedirs(destination_dir, exist_ok=True)

            shutil.move(file_path, os.path.join(destination_dir, filename))
            print(f"Moved: '{filename}' to '{ext_name}' folder")
            organized_count += 1

        except Exception as e:
            print(f"Error processing '{filename}': {e}")
            error_count += 1

    print("-" * 50)
    print("Extension-based Organization Complete!")
    print(f"Files organized: {organized_count}")
    print(f"Files skipped (directories): {skipped_count}")
    print(f"Files with errors: {error_count}")
    print(f"Total items processed: {len(os.listdir(source_directory)) + skipped_count}")

def get_file_summary(directory):
    """
    Analyzes a directory and returns a summary of file types and their counts.

    Args:
        directory (str): The path to the directory to analyze.

    Returns:
        dict: A dictionary where keys are file extensions (e.g., '.txt', '.jpg')
              and values are the counts of files with that extension.
              Returns an empty dictionary if the directory doesn't exist or is empty.
    """
    if not os.path.isdir(directory):
        print(f"Error: Directory '{directory}' not found for summary.")
        return {}

    file_counts = collections.defaultdict(int)
    for root, _, files in os.walk(directory):
        for filename in files:
            _, ext = os.path.splitext(filename)
            file_counts[ext.lower()] += 1
    return dict(file_counts)

def organize_files_by_date(source_directory):
    """
    Organizes files in a given directory into subfolders based on their
    creation date (Year/Month).

    Args:
        source_directory (str): The path to the directory to organize.
    """
    if not os.path.isdir(source_directory):
        print(f"Error: Directory '{source_directory}' not found.")
        return

    print(f"Starting file organization in: {source_directory}")
    print("-" * 50)

    organized_count = 0
    skipped_count = 0
    error_count = 0

    for filename in os.listdir(source_directory):
        file_path = os.path.join(source_directory, filename)

        # Skip directories themselves
        if os.path.isdir(file_path):
            print(f"Skipping directory: {filename}")
            skipped_count += 1
            continue

        try:
            # Get creation time (Windows/Linux compatible)
            # st_ctime is creation time on Windows, last metadata change on Unix
            # st_mtime is last modification time
            # For general purpose, modification time is often more reliable/consistent
            # across OSes for "when it was last touched/finished"
            timestamp = os.path.getmtime(file_path)
            creation_date = datetime.datetime.fromtimestamp(timestamp)

            year = creation_date.strftime('%Y')
            month = creation_date.strftime('%m - %B') # e.g., "01 - January"

            destination_dir = os.path.join(source_directory, year, month)

            # Create destination directory if it doesn't exist
            os.makedirs(destination_dir, exist_ok=True)

            # Move the file
            shutil.move(file_path, os.path.join(destination_dir, filename))
            print(f"Moved: '{filename}' to '{os.path.join(year, month)}'")
            organized_count += 1

        except Exception as e:
            print(f"Error processing '{filename}': {e}")
            error_count += 1

    print("-" * 50)
    print("Organization Complete!")
    print(f"Files organized: {organized_count}")
    print(f"Files skipped (directories): {skipped_count}")
    print(f"Files with errors: {error_count}")
    print(f"Total items processed: {len(os.listdir(source_directory)) + skipped_count}") # + skipped_count because os.listdir doesn't count them initially


if __name__ == "__main__":
    # --- IMPORTANT: Configure this before running! ---
    # It's highly recommended to test this on a *copy* of your directory first.
    # Replace this with the actual path to the directory you want to organize.
    # Example:
    # directory_to_organize = "/Users/yourusername/Downloads"
    # directory_to_organize = "C:\\Users\\yourusername\\Desktop"
    directory_to_organize = "./test_files_to_organize" # For testing: creates a local dir

    # --- For Testing: Create some dummy files and folders ---
    if directory_to_organize == "./test_files_to_organize":
        os.makedirs(directory_to_organize, exist_ok=True)
        print(f"Creating dummy files in '{directory_to_organize}' for testing...")
        # Files from "last year"
        with open(os.path.join(directory_to_organize, "old_document.txt"), "w") as f:
            f.write("This is an old document.")
        os.utime(os.path.join(directory_to_organize, "old_document.txt"), (datetime.datetime.now().timestamp() - 365*24*60*60, datetime.datetime.now().timestamp() - 365*24*60*60)) # Set mtime to 1 year ago

        # Files from "last month"
        with open(os.path.join(directory_to_organize, "report_last_month.pdf"), "w") as f:
            f.write("Last month's report.")
        os.utime(os.path.join(directory_to_organize, "report_last_month.pdf"), (datetime.datetime.now().timestamp() - 30*24*60*60, datetime.datetime.now().timestamp() - 30*24*60*60)) # Set mtime to 1 month ago

        # Files from "today"
        with open(os.path.join(directory_to_organize, "photo_001.jpg"), "w") as f:
            f.write("Dummy JPEG content.")
        with open(os.path.join(directory_to_organize, "new_spreadsheet.xlsx"), "w") as f:
            f.write("Dummy Excel content.")
        os.makedirs(os.path.join(directory_to_organize, "existing_subfolder"), exist_ok=True)
        with open(os.path.join(directory_to_organize, "existing_subfolder", "file_in_sub.txt"), "w") as f:
            f.write("This file is in a subfolder and should be skipped.")
        print("Dummy files created. Running organization...")
        print("-" * 50)
    # --- End of Testing setup ---

    # Call the function with your chosen directory
    organize_files_by_date(directory_to_organize)

    # --- For Testing: Clean up dummy files if used ---
    if directory_to_organize == "./test_files_to_organize":
        print("\nCleaning up dummy test directory...")
        try:
            # Be careful with rmtree! Only use on known test directories.
            shutil.rmtree(directory_to_organize)
            print(f"Successfully removed '{directory_to_organize}'")
        except OSError as e:
            print(f"Error removing test directory: {e}")

