// ============================================================================
// Backup Management Tool - Website JavaScript
// Fetches release data from GitHub API and renders dynamically
// ============================================================================

const GITHUB_REPO = 'wnstify/backup-management-tool';
const GITHUB_API = `https://api.github.com/repos/${GITHUB_REPO}/releases`;

// DOM Elements
const versionBadge = document.getElementById('latest-version');
const changelogContent = document.getElementById('changelog-content');
const downloadVersion = document.getElementById('download-version');
const downloadDate = document.getElementById('download-date');
const downloadTarBtn = document.getElementById('download-tar');
const terminalVersion = document.getElementById('terminal-version');

// Mobile menu toggle (BEM classes)
const mobileMenuBtn = document.querySelector('.navbar__menu-btn');
const navLinks = document.querySelector('.navbar__links');

if (mobileMenuBtn && navLinks) {
    mobileMenuBtn.addEventListener('click', () => {
        navLinks.classList.toggle('navbar__links--active');
        mobileMenuBtn.classList.toggle('navbar__menu-btn--active');
    });

    // Close menu when clicking a link
    navLinks.querySelectorAll('a').forEach(link => {
        link.addEventListener('click', () => {
            navLinks.classList.remove('navbar__links--active');
            mobileMenuBtn.classList.remove('navbar__menu-btn--active');
        });
    });
}

// Copy to clipboard functionality
function copyToClipboard(elementId, btn) {
    const element = document.getElementById(elementId);
    const text = element.textContent;

    navigator.clipboard.writeText(text).then(() => {
        // Show feedback
        const originalHTML = btn.innerHTML;
        btn.innerHTML = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="20 6 9 17 4 12"></polyline></svg>';
        btn.style.color = '#4ade80';

        setTimeout(() => {
            btn.innerHTML = originalHTML;
            btn.style.color = '';
        }, 2000);
    }).catch(err => {
        console.error('Failed to copy:', err);
    });
}

// Set up copy buttons using event listeners (CSP-compliant, BEM classes)
document.querySelectorAll('.code-block__copy[data-copy-target]').forEach(btn => {
    btn.addEventListener('click', () => {
        const targetId = btn.getAttribute('data-copy-target');
        copyToClipboard(targetId, btn);
    });
});

// Format date
function formatDate(dateString) {
    const date = new Date(dateString);
    return date.toLocaleDateString('en-US', {
        year: 'numeric',
        month: 'long',
        day: 'numeric'
    });
}

// Escape HTML to prevent XSS
function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

// Parse markdown-like release notes to HTML (with sanitization)
function parseReleaseBody(body) {
    if (!body) return '<p>No release notes available.</p>';

    // First escape all HTML to prevent XSS
    let escaped = escapeHtml(body);

    let html = escaped
        // Headers
        .replace(/^### (.+)$/gm, '<h3>$1</h3>')
        .replace(/^## (.+)$/gm, '<h3>$1</h3>')
        // Bold
        .replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>')
        // Code blocks
        .replace(/`([^`]+)`/g, '<code>$1</code>')
        // List items
        .replace(/^[-*] (.+)$/gm, '<li>$1</li>')
        // Line breaks
        .replace(/\n\n/g, '</p><p>')
        .replace(/\n/g, '<br>');

    // Wrap consecutive list items in ul
    html = html.replace(/(<li>.*?<\/li>(?:<br>)?)+/g, (match) => {
        return '<ul>' + match.replace(/<br>/g, '') + '</ul>';
    });

    return html;
}

// Create release card HTML (BEM classes)
function createReleaseCard(release, isLatest = false) {
    const card = document.createElement('div');
    card.className = 'card card--release';
    if (isLatest) card.classList.add('card--release-latest');

    // Sanitize tag_name to prevent XSS
    const safeTagName = escapeHtml(release.tag_name);

    card.innerHTML = `
        <div class="release__header">
            <span class="release__version">${safeTagName}${isLatest ? ' (Latest)' : ''}</span>
            <span class="release__date">${formatDate(release.published_at)}</span>
        </div>
        <div class="release__body">
            ${parseReleaseBody(release.body)}
        </div>
    `;

    return card;
}

// Fetch and render releases
async function fetchReleases() {
    try {
        const response = await fetch(GITHUB_API);

        if (!response.ok) {
            throw new Error(`GitHub API returned ${response.status}`);
        }

        const releases = await response.json();

        if (releases.length === 0) {
            changelogContent.innerHTML = '<p class="no-releases">No releases found.</p>';
            return;
        }

        // Get latest release
        const latestRelease = releases[0];

        // Update version badge (textContent is safe, auto-escapes)
        versionBadge.textContent = `Latest: ${latestRelease.tag_name}`;

        // Update terminal version
        if (terminalVersion) {
            terminalVersion.textContent = latestRelease.tag_name;
        }

        // Update download section (textContent is safe, auto-escapes)
        downloadVersion.textContent = `Version ${latestRelease.tag_name}`;
        downloadDate.textContent = `Released on ${formatDate(latestRelease.published_at)}`;

        // Find tar.gz asset and validate URL
        const tarAsset = latestRelease.assets.find(asset => asset.name.endsWith('.tar.gz'));
        if (tarAsset && tarAsset.browser_download_url) {
            // Validate URL is from GitHub
            const url = new URL(tarAsset.browser_download_url);
            if (url.hostname === 'github.com' || url.hostname.endsWith('.githubusercontent.com')) {
                downloadTarBtn.href = tarAsset.browser_download_url;
            } else {
                downloadTarBtn.href = `https://github.com/${GITHUB_REPO}/releases/latest`;
            }
        } else if (latestRelease.tarball_url) {
            // Validate tarball URL is from GitHub
            const url = new URL(latestRelease.tarball_url);
            if (url.hostname === 'api.github.com' || url.hostname === 'github.com') {
                downloadTarBtn.href = latestRelease.tarball_url;
            } else {
                downloadTarBtn.href = `https://github.com/${GITHUB_REPO}/releases/latest`;
            }
        } else {
            downloadTarBtn.href = `https://github.com/${GITHUB_REPO}/releases/latest`;
        }

        // Clear loading spinner
        changelogContent.innerHTML = '';

        // Render last 5 releases
        const recentReleases = releases.slice(0, 5);
        recentReleases.forEach((release, index) => {
            const card = createReleaseCard(release, index === 0);
            changelogContent.appendChild(card);
        });

    } catch (error) {
        console.error('Failed to fetch releases:', error);

        // Show error message
        changelogContent.innerHTML = `
            <div class="card card--release">
                <p>Unable to load release notes. Please check the <a href="https://github.com/${GITHUB_REPO}/releases" target="_blank" rel="noopener noreferrer">GitHub releases page</a>.</p>
            </div>
        `;

        // Set fallback values
        versionBadge.textContent = 'Latest Release';
        downloadVersion.textContent = 'Download Latest';
        downloadTarBtn.href = `https://github.com/${GITHUB_REPO}/releases/latest`;
    }
}

// Smooth scroll for anchor links
document.querySelectorAll('a[href^="#"]').forEach(anchor => {
    anchor.addEventListener('click', function(e) {
        const href = this.getAttribute('href');
        if (href === '#') return;

        e.preventDefault();
        const target = document.querySelector(href);
        if (target) {
            const navHeight = document.querySelector('.navbar').offsetHeight;
            const targetPosition = target.offsetTop - navHeight - 20;

            window.scrollTo({
                top: targetPosition,
                behavior: 'smooth'
            });
        }
    });
});

// Navbar background on scroll
const navbar = document.querySelector('.navbar');
let lastScroll = 0;

window.addEventListener('scroll', () => {
    const currentScroll = window.pageYOffset;

    if (currentScroll > 100) {
        navbar.style.background = 'rgba(21, 20, 21, 0.95)';
    } else {
        navbar.style.background = 'rgba(21, 20, 21, 0.8)';
    }

    lastScroll = currentScroll;
});

// Intersection Observer for animations (using CSS classes to avoid forced reflow)
const observerOptions = {
    threshold: 0.1,
    rootMargin: '0px 0px -50px 0px'
};

const observer = new IntersectionObserver((entries) => {
    entries.forEach(entry => {
        if (entry.isIntersecting) {
            entry.target.classList.add('animate-on-scroll--visible');
        }
    });
}, observerOptions);

// Observe feature cards and other animated elements (BEM classes)
document.querySelectorAll('.card--feature, .step, .card--release').forEach(el => {
    el.classList.add('animate-on-scroll');
    observer.observe(el);
});

// Initialize
document.addEventListener('DOMContentLoaded', () => {
    fetchReleases();
});
